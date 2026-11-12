from __future__ import annotations

import asyncio
import json
import mimetypes
import os
import re
from pathlib import Path
from typing import Any, AsyncIterator
from urllib.parse import quote, urljoin, urlparse

import httpx
from fastapi import HTTPException

from . import config
from .search import parse_filename, score_items

VIDEO_EXTS = {".mkv", ".mp4", ".avi", ".mov", ".webm", ".m4v", ".ts", ".mpg", ".mpeg", ".m3u", ".m3u8", ".m4s"}


def dotted_get(obj: Any, path: str | None, default: Any = None) -> Any:
    if not path:
        return obj
    current = obj
    for part in path.split("."):
        if isinstance(current, list):
            try:
                current = current[int(part)]
            except (ValueError, IndexError):
                return default
        elif isinstance(current, dict):
            current = current.get(part)
        else:
            return default
        if current is None:
            return default
    return current


def _extract_rows(data: Any, items_path: str | None, label: str) -> list[Any]:
    """Resolve common API envelopes while allowing an explicit dotted field path."""
    candidate = dotted_get(data, items_path, None) if items_path else data
    if isinstance(candidate, list):
        return candidate
    if isinstance(candidate, dict):
        for key in ("items", "files", "results", "rows", "data"):
            value = candidate.get(key)
            if isinstance(value, list):
                return value
    if isinstance(data, list):
        return data
    if isinstance(data, dict):
        for path in ("files", "items", "data.files", "data.items", "results", "rows", "data"):
            value = dotted_get(data, path, None)
            if isinstance(value, list):
                return value
    raise HTTPException(422, f"{label} response does not contain an array; configure items_path")


def _infer_filename_metadata(title: str) -> dict[str, int | None]:
    year_match = re.search(r"\b(19\d{2}|20\d{2})\b", title)
    episode_match = re.search(r"[Ss](\d{1,2})[ ._-]*[Ee](\d{1,3})", title)
    if not episode_match:
        episode_match = re.search(r"Season[ ._-]*(\d{1,2}).{0,20}Episode[ ._-]*(\d{1,3})", title, re.IGNORECASE)
    return {
        "year": int(year_match.group(1)) if year_match else None,
        "season": int(episode_match.group(1)) if episode_match else None,
        "episode": int(episode_match.group(2)) if episode_match else None,
    }


def clean_item(source: dict[str, Any], item_id: Any, title: Any, **kwargs: Any) -> dict[str, Any]:
    filename = str(title or "Untitled")
    ext = Path(filename).suffix.lower()
    mime = kwargs.get("mime_type") or mimetypes.guess_type(filename)[0] or "application/octet-stream"
    inferred = parse_filename(filename)
    display_title = Path(filename).stem or filename
    return {
        "id": str(item_id), "source_id": source["id"], "source_name": source["name"],
        "title": display_title, "filename": filename,
        "kind": kwargs.get("kind") or ("video" if ext in VIDEO_EXTS or mime.startswith("video/") else "file"),
        "size": int(kwargs.get("size") or 0), "mime_type": mime,
        "poster": kwargs.get("poster"), "description": kwargs.get("description"),
        "year": _safe_int(kwargs.get("year")) or inferred["year"],
        "season": _safe_int(kwargs.get("season")) or inferred["season"],
        "episode": _safe_int(kwargs.get("episode")) or inferred["episode"],
        "series": kwargs.get("series") or inferred["series"],
        "quality": kwargs.get("quality") or inferred["quality"],
        "codec": kwargs.get("codec") or inferred["codec"],
        "duration": kwargs.get("duration"), "stream_url": f"/api/stream/{source['id']}/{item_id}",
        "external_url": kwargs.get("external_url"), "added_at": kwargs.get("added_at"),
    }


class BaseAdapter:
    async def list_items(self, source: dict[str, Any], query: str = "") -> list[dict[str, Any]]:
        raise NotImplementedError

    async def stream(self, source: dict[str, Any], item_id: str, range_header: str | None):
        raise NotImplementedError


class JsonAdapter(BaseAdapter):
    async def _load(self, cfg: dict[str, Any]) -> Any:
        if cfg.get("url"):
            headers = _configured_headers(cfg)
            async with httpx.AsyncClient(timeout=config.REQUEST_TIMEOUT, follow_redirects=True) as client:
                response = await client.get(cfg["url"], headers=headers)
                response.raise_for_status()
                if len(response.content) > config.MAX_JSON_BYTES:
                    raise HTTPException(413, "JSON catalog exceeds configured size limit")
                return response.json()
        file_path = Path(cfg.get("file_path", "")).expanduser()
        if not file_path.is_absolute():
            file_path = (config.DATA_DIR / file_path).resolve()
        else:
            file_path = file_path.resolve()
        if not file_path.is_relative_to(config.DATA_DIR):
            raise HTTPException(403, "Local JSON catalogs must be inside the backend data directory")
        if not file_path.exists() or not file_path.is_file():
            raise HTTPException(404, "JSON catalog file not found; upload a catalog or configure a URL")
        if file_path.stat().st_size > config.MAX_JSON_BYTES:
            raise HTTPException(413, "JSON catalog exceeds configured size limit")
        return json.loads(file_path.read_text(encoding="utf-8"))

    async def list_items(self, source: dict[str, Any], query: str = "") -> list[dict[str, Any]]:
        cfg = source["config"]
        data = await self._load(cfg)
        rows = _extract_rows(data, cfg.get("items_path", "items"), "JSON catalog")
        out = []
        for index, row in enumerate(rows):
            if not isinstance(row, dict):
                continue
            media = _normalize_rest_row(source, row, cfg, str(row.get("id", index)))
            if media:
                out.append(media)
        return _filter_items(out, query)

    async def stream(self, source: dict[str, Any], item_id: str, range_header: str | None):
        cfg = source["config"]
        data = await self._load(cfg)
        rows = _extract_rows(data, cfg.get("items_path", "items"), "JSON catalog")
        for index, row in enumerate(rows):
            rid = str(dotted_get(row, cfg.get("id_field", "id"), index))
            if rid == item_id:
                url = dotted_get(row, cfg.get("url_field", "url"))
                if not url:
                    raise HTTPException(404, "No stream URL is defined for this catalog item")
                return await proxy_http_stream(str(url), _configured_headers(cfg), range_header)
        raise HTTPException(404, "Catalog item not found")


class M3uAdapter(BaseAdapter):
    """Imports an M3U playlist (HTTP URL or local file) as virtual media entries."""
    async def _text(self, cfg: dict[str, Any]) -> str:
        if cfg.get("url"):
            async with httpx.AsyncClient(timeout=config.REQUEST_TIMEOUT, follow_redirects=True) as client:
                response = await client.get(cfg["url"], headers=_configured_headers(cfg))
                response.raise_for_status()
                if len(response.content) > config.MAX_JSON_BYTES:
                    raise HTTPException(413, "Playlist exceeds configured size limit")
                return response.text
        path = Path(cfg.get("file_path", "")).expanduser()
        if not path.is_absolute():
            path = (config.DATA_DIR / path).resolve()
        else:
            path = path.resolve()
        if not path.is_relative_to(config.DATA_DIR):
            raise HTTPException(403, "Local M3U playlists must be inside the backend data directory")
        if not path.is_file() or path.stat().st_size > config.MAX_JSON_BYTES:
            raise HTTPException(404, "M3U playlist file not found or too large")
        return path.read_text(encoding="utf-8-sig")

    async def list_items(self, source: dict[str, Any], query: str = "") -> list[dict[str, Any]]:
        lines = [line.strip() for line in (await self._text(source["config"])).splitlines() if line.strip()]
        entries: list[dict[str, Any]] = []
        title, poster, item_id = None, None, None
        for line in lines:
            if line.startswith("#EXTINF"):
                title = line.rsplit(",", 1)[-1].strip() or None
                logo = re.search(r'tvg-logo=["\']([^"\']+)', line, re.IGNORECASE)
                poster = logo.group(1) if logo else None
                id_match = re.search(r'tvg-id=["\']([^"\']+)', line, re.IGNORECASE)
                item_id = id_match.group(1) if id_match else None
            elif not line.startswith("#"):
                playlist_url = source["config"].get("url")
                media_url = urljoin(playlist_url, line) if playlist_url else line
                if urlparse(media_url).scheme not in {"http", "https"}:
                    title, poster, item_id = None, None, None
                    continue
                name = title or Path(urlparse(media_url).path).name or f"Playlist item {len(entries)+1}"
                entries.append(clean_item(source, item_id or len(entries), name, poster=poster, external_url=media_url))
                title, poster, item_id = None, None, None
        return _filter_items(entries, query)

    async def stream(self, source: dict[str, Any], item_id: str, range_header: str | None):
        items = await self.list_items(source)
        item = next((x for x in items if x["id"] == item_id), None)
        if not item or not item.get("external_url"):
            raise HTTPException(404, "Playlist media item not found")
        return await proxy_http_stream(item["external_url"], _configured_headers(source["config"]), range_header)


class LinkAdapter(BaseAdapter):
    async def list_items(self, source: dict[str, Any], query: str = "") -> list[dict[str, Any]]:
        cfg = source["config"]
        links = cfg.get("links") or ([{"url": cfg.get("url"), "title": cfg.get("title")} ] if cfg.get("url") else [])
        out = []
        for index, link in enumerate(links):
            if isinstance(link, str):
                link = {"url": link}
            url = link.get("url")
            if not url:
                continue
            title = link.get("title") or Path(urlparse(url).path).name or f"Media {index + 1}"
            out.append(clean_item(source, link.get("id", index), title, size=link.get("size"), mime_type=link.get("mime_type"), poster=link.get("poster"), external_url=url))
        return _filter_items(out, query)

    async def stream(self, source: dict[str, Any], item_id: str, range_header: str | None):
        items = await self.list_items(source)
        item = next((x for x in items if x["id"] == item_id), None)
        if not item or not item.get("external_url"):
            raise HTTPException(404, "Link not found")
        return await proxy_http_stream(item["external_url"], _configured_headers(source["config"]), range_header)


class RestAdapter(BaseAdapter):
    def _base(self, cfg: dict[str, Any]) -> str:
        base = str(cfg.get("base_url", "")).rstrip("/")
        if not base.startswith(("http://", "https://")):
            raise HTTPException(422, "Source base_url must be an HTTP or HTTPS URL")
        return base

    async def list_items(self, source: dict[str, Any], query: str = "") -> list[dict[str, Any]]:
        cfg = source["config"]
        url = self._base(cfg) + str(cfg.get("list_path", "/media"))
        params = cfg.get("list_params", {})
        body = cfg.get("list_body", {})
        method = str(cfg.get("list_method", "GET")).upper()
        if method not in {"GET", "POST"}:
            raise HTTPException(422, "REST list_method must be GET or POST")
        if not isinstance(params, dict) or not isinstance(body, dict):
            raise HTTPException(422, "REST list_params and list_body must be JSON objects")
        if query and cfg.get("search_param"):
            if method == "POST" and cfg.get("search_in_body", True):
                body = {**body, cfg["search_param"]: query}
            else:
                params = {**params, cfg["search_param"]: query}
        async with httpx.AsyncClient(timeout=config.REQUEST_TIMEOUT, follow_redirects=True) as client:
            response = await client.request(method, url, params=params, json=body if method == "POST" else None,
                                            headers=_configured_headers(cfg))
            response.raise_for_status()
            data = response.json()
        rows = _extract_rows(data, cfg.get("items_path", "items"), "REST")
        out = []
        for index, row in enumerate(rows):
            if not isinstance(row, dict):
                continue
            media = _normalize_rest_row(source, row, cfg, str(index))
            if media:
                out.append(media)
        return _filter_items(out, query)

    async def stream(self, source: dict[str, Any], item_id: str, range_header: str | None):
        cfg = source["config"]
        if cfg.get("download_path"):
            url = self._base(cfg) + cfg["download_path"].replace("{id}", quote(item_id, safe=""))
        else:
            items = await self.list_items(source)
            item = next((x for x in items if x["id"] == item_id), None)
            if not item or not item.get("external_url"):
                raise HTTPException(404, "REST item has no download URL")
            url = item["external_url"]
        return await proxy_http_stream(url, _configured_headers(cfg), range_header)


class TeldriveAdapter(RestAdapter):
    """Adapter for Teldrive's file API; endpoint and field mappings are overridable."""
    def _config(self, source: dict[str, Any]) -> dict[str, Any]:
        return {
            "list_path": "/api/files", "items_path": "files", "id_field": "id", "title_field": "name",
            "mime_field": "mime_type", "size_field": "size", "hash_field": "hash",
            "download_path": "/api/files/{id}/{name}?hash={hash}&download=1", "type_field": "type",
            "list_params": {"page": 1, "order": "asc", "sort": "name", "path": "/"},
            "auth_header": "X-Api-Key", "auth_prefix": "", **source["config"],
        }

    async def list_items(self, source: dict[str, Any], query: str = "") -> list[dict[str, Any]]:
        configured = {**source, "config": self._config(source)}
        return await super().list_items(configured, query)

    async def _get_file_metadata(self, cfg: dict[str, Any], item_id: str) -> dict[str, Any]:
        detail_path = str(cfg.get("detail_path", "/api/files/{id}"))
        url = self._base(cfg) + detail_path.replace("{id}", quote(item_id, safe=""))
        async with httpx.AsyncClient(timeout=config.REQUEST_TIMEOUT, follow_redirects=True) as client:
            response = await client.get(url, headers=_configured_headers(cfg))
            # Some Teldrive releases expose file details only through the list
            # endpoint and the name/hash download route. Treat only a missing
            # detail route as a compatibility case; authentication/server
            # failures must remain visible to the user.
            if response.status_code in {404, 405}:
                return {}
            response.raise_for_status()
            data = response.json()
        if isinstance(data, dict):
            for key in ("file", "item", "data"):
                if isinstance(data.get(key), dict):
                    return data[key]
            return data
        return {}

    async def stream(self, source: dict[str, Any], item_id: str, range_header: str | None):
        cfg = self._config(source)
        configured = {**source, "config": cfg}
        template = str(cfg.get("download_path") or "")
        if "{name}" in template or "{hash}" in template:
            row = await self._get_file_metadata(cfg, item_id)
            name = dotted_get(row, cfg.get("title_field", "name"))
            file_hash = dotted_get(row, cfg.get("hash_field", "hash"))
            # A list lookup is a compatibility fallback for servers without a detail endpoint.
            if not name or ("{hash}" in template and not file_hash):
                items = await super().list_items(configured)
                item = next((entry for entry in items if entry["id"] == item_id), None)
                if item:
                    name = name or item.get("filename")
                    file_hash = file_hash or item.get("storage_hash")
            if not name:
                raise HTTPException(404, "Teldrive file metadata not found")
            url = self._base(cfg) + template.replace("{id}", quote(item_id, safe=""))
            url = url.replace("{name}", quote(str(name), safe=""))
            url = url.replace("{hash}", quote(str(file_hash or ""), safe=""))
            return await proxy_http_stream(url, _configured_headers(cfg), range_header)
        # Older Teldrive deployments can use /api/files/{id}/content; override download_path.
        return await super().stream(configured, item_id, range_header)


class TelegramAdapter(BaseAdapter):
    def __init__(self) -> None:
        self._client: TelegramClient | None = None
        self._lock = asyncio.Lock()

    async def _get_client(self) -> TelegramClient:
        try:
            from telethon import TelegramClient
            from telethon.sessions import StringSession
        except ImportError as exc:
            raise HTTPException(503, "Install backend requirements to enable Telegram MTProto") from exc
        async with self._lock:
            if self._client is None:
                if not (config.TELEGRAM_API_ID and config.TELEGRAM_API_HASH):
                    raise HTTPException(503, "Configure TELEGRAM_API_ID and TELEGRAM_API_HASH on the backend")
                try:
                    api_id = int(config.TELEGRAM_API_ID)
                except ValueError as exc:
                    raise HTTPException(500, "TELEGRAM_API_ID must be an integer") from exc
                session = StringSession(config.TELEGRAM_SESSION) if config.TELEGRAM_SESSION else str(config.TELEGRAM_SESSION_FILE)
                self._client = TelegramClient(session, api_id, config.TELEGRAM_API_HASH)
            if not self._client.is_connected():
                await self._client.connect()
            if not await self._client.is_user_authorized():
                raise HTTPException(503, "Telegram MTProto session is not authorized. Create a session string and configure TELEGRAM_SESSION.")
            return self._client

    async def list_items(self, source: dict[str, Any], query: str = "") -> list[dict[str, Any]]:
        cfg = source["config"]
        channel = cfg.get("channel")
        if not channel:
            raise HTTPException(422, "Telegram source requires channel, e.g. @mychannel")
        client = await self._get_client()
        limit = min(max(int(cfg.get("limit", 500)), 1), 2000)
        try:
            entity = await client.get_entity(channel)
            out = []
            async for msg in client.iter_messages(entity, limit=limit):
                file = msg.file
                if not file or not (file.mime_type or "").startswith("video/") and not Path(file.name or "").suffix.lower() in VIDEO_EXTS:
                    continue
                title = file.name or f"telegram-{msg.id}.video"
                attrs = getattr(msg.document, "attributes", []) if msg.document else []
                duration = next((getattr(a, "duration", None) for a in attrs if hasattr(a, "duration")), None)
                out.append(clean_item(source, msg.id, title, size=file.size, mime_type=file.mime_type,
                                      description=(msg.message or "")[:1000], duration=duration,
                                      added_at=msg.date.isoformat() if msg.date else None))
            return _filter_items(out, query)
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(502, f"Telegram catalog error: {exc}") from exc

    async def stream(self, source: dict[str, Any], item_id: str, range_header: str | None):
        client = await self._get_client()
        try:
            channel = source["config"].get("channel")
            message = await client.get_messages(channel, ids=int(item_id))
            if not message or not message.document:
                raise HTTPException(404, "Telegram media message not found")
            doc = message.document
            total = int(doc.size)
            start, end, partial = parse_range(range_header, total)
            length = end - start + 1
            chunk_size = 512 * 1024

            async def body() -> AsyncIterator[bytes]:
                sent = 0
                async for chunk in client.iter_download(doc, offset=start, limit=(length + chunk_size - 1) // chunk_size + 1,
                                                        chunk_size=chunk_size, request_size=chunk_size, file_size=total):
                    if not chunk:
                        continue
                    remaining = length - sent
                    if remaining <= 0:
                        break
                    part = chunk[:remaining]
                    sent += len(part)
                    yield part
                    if sent >= length:
                        break

            headers = {"Accept-Ranges": "bytes", "Content-Length": str(length),
                       "Content-Type": message.file.mime_type or "application/octet-stream",
                       "Content-Disposition": f'inline; filename="{_safe_filename(message.file.name or f"telegram-{item_id}.bin")}"'}
            if partial:
                headers["Content-Range"] = f"bytes {start}-{end}/{total}"
            from fastapi.responses import StreamingResponse
            return StreamingResponse(body(), status_code=206 if partial else 200, headers=headers)
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(502, f"Telegram stream error: {exc}") from exc


def _normalize_rest_row(source: dict[str, Any], row: dict[str, Any], cfg: dict[str, Any], fallback_id: str) -> dict[str, Any] | None:
    if cfg.get("type_field") and str(row.get(cfg["type_field"], "")).lower() in {"folder", "directory", "dir"}:
        return None
    get = lambda key, default=None: dotted_get(row, cfg.get(key, key.removesuffix("_field")), default)
    item_id = get("id_field", fallback_id)
    title = get("title_field", f"Media {fallback_id}")
    url = get("url_field")
    download_path = cfg.get("download_path")
    external = str(url) if url else None
    item = clean_item(source, item_id, title,
                      size=get("size_field", 0), mime_type=get("mime_field"),
                      poster=get("poster_field"), description=get("description_field"),
                      year=get("year_field"), season=get("season_field"), episode=get("episode_field"),
                      series=get("series_field"), quality=get("quality_field"), codec=get("codec_field"),
                      duration=get("duration_field"), external_url=external,
                      added_at=get("date_field"))
    if download_path:
        item["external_url"] = None
    if cfg.get("hash_field"):
        item["storage_hash"] = dotted_get(row, cfg["hash_field"])
    return item


def _configured_headers(cfg: dict[str, Any]) -> dict[str, str]:
    headers = {str(k): str(v) for k, v in (cfg.get("headers") or {}).items()}
    token_env = cfg.get("token_env")
    if token_env:
        token = os.getenv(str(token_env), "")
        if token:
            header_name = cfg.get("auth_header", "Authorization")
            prefix = cfg.get("auth_prefix", "Bearer ")
            headers[header_name] = f"{prefix}{token}"
    cookie_env = cfg.get("cookie_env")
    if cookie_env and os.getenv(str(cookie_env)):
        headers["Cookie"] = os.environ[str(cookie_env)]
    return headers


def _safe_int(value: Any) -> int | None:
    try:
        return int(value) if value is not None and str(value).strip() else None
    except (TypeError, ValueError):
        return None


def _filter_items(items: list[dict[str, Any]], query: str) -> list[dict[str, Any]]:
    return score_items(items, query, config.CATALOG_LIMIT)


def parse_range(value: str | None, total: int) -> tuple[int, int, bool]:
    if not value:
        return 0, max(0, total - 1), False
    match = re.fullmatch(r"bytes=(\d*)-(\d*)", value.strip())
    if not match or total <= 0:
        raise HTTPException(416, "Invalid byte range", headers={"Content-Range": f"bytes */{total}"})
    a, b = match.groups()
    if not a and not b:
        raise HTTPException(416, "Invalid byte range", headers={"Content-Range": f"bytes */{total}"})
    if not a:
        suffix = int(b)
        start = max(0, total - suffix)
        end = total - 1
    else:
        start = int(a)
        end = min(int(b) if b else total - 1, total - 1)
    if start >= total or start > end:
        raise HTTPException(416, "Requested range is not satisfiable", headers={"Content-Range": f"bytes */{total}"})
    return start, end, True


async def proxy_http_stream(url: str, headers: dict[str, str], range_header: str | None):
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise HTTPException(422, "Only HTTP and HTTPS media URLs are supported")
    request_headers = dict(headers)
    if range_header:
        request_headers["Range"] = range_header
    client = httpx.AsyncClient(timeout=None, follow_redirects=True)
    try:
        req = client.build_request("GET", url, headers=request_headers)
        response = await client.send(req, stream=True)
        if response.status_code >= 400:
            message = f"Upstream stream returned HTTP {response.status_code}"
            await response.aclose()
            await client.aclose()
            raise HTTPException(response.status_code, message)
        passthrough = {k: v for k, v in response.headers.items() if k.lower() in {
            "content-type", "content-length", "content-range", "accept-ranges", "etag", "last-modified", "content-disposition"}}

        async def body():
            try:
                async for chunk in response.aiter_bytes(1024 * 256):
                    yield chunk
            finally:
                await response.aclose()
                await client.aclose()

        from fastapi.responses import StreamingResponse
        return StreamingResponse(body(), status_code=response.status_code, headers=passthrough)
    except HTTPException:
        raise
    except Exception as exc:
        await client.aclose()
        raise HTTPException(502, f"Upstream stream failed: {exc}") from exc


def _safe_filename(value: str) -> str:
    return re.sub(r'[\\"\r\n]', "_", value)[:180]


ADAPTERS: dict[str, BaseAdapter] = {
    "json": JsonAdapter(), "link": LinkAdapter(), "m3u": M3uAdapter(), "rest": RestAdapter(),
    "teldrive": TeldriveAdapter(), "telegram": TelegramAdapter(),
}


def adapter_for(kind: str) -> BaseAdapter:
    adapter = ADAPTERS.get(kind)
    if not adapter:
        raise HTTPException(422, f"Unsupported source type: {kind}")
    return adapter
