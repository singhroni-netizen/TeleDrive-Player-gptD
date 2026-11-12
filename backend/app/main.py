from __future__ import annotations

import asyncio
import json
import secrets
import shutil
import uuid
from pathlib import Path
from typing import Any, Literal

from fastapi import Depends, FastAPI, File, Header, HTTPException, Query, Request, UploadFile
from fastapi.responses import StreamingResponse
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from . import config, db
from .sources import adapter_for
from .search import gemini_rank, score_items, virtual_tree

app = FastAPI(
    title="TeleDrive Player API",
    version="0.1.0",
    description="Private media catalog and HTTP Range streaming gateway.",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=config.CORS_ORIGINS,
    allow_credentials=False,
    allow_methods=["GET", "POST", "PATCH", "DELETE", "OPTIONS", "HEAD"],
    allow_headers=["*"],
)


class SourceCreate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    kind: Literal["telegram", "teldrive", "json", "rest", "link", "m3u"]
    config: dict[str, Any] = Field(default_factory=dict)
    enabled: bool = True


class SourceToggle(BaseModel):
    enabled: bool


class SourceUpdate(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    kind: Literal["telegram", "teldrive", "json", "rest", "link", "m3u"]
    config: dict[str, Any] = Field(default_factory=dict)


class ProgressUpdate(BaseModel):
    item_key: str = Field(min_length=1, max_length=300)
    position_ms: int = Field(ge=0)
    duration_ms: int = Field(ge=0)


async def check_api_key(x_api_key: str | None = Header(default=None)) -> None:
    if config.API_KEY and not secrets.compare_digest(x_api_key or "", config.API_KEY):
        raise HTTPException(401, "Invalid or missing API key")


@app.on_event("startup")
async def startup() -> None:
    db.init_db()


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok", "service": "teledrive-player-api", "version": app.version}


@app.get("/api/sources", dependencies=[Depends(check_api_key)])
async def get_sources() -> list[dict[str, Any]]:
    return db.list_sources()


@app.post("/api/sources", status_code=201, dependencies=[Depends(check_api_key)])
async def add_source(body: SourceCreate) -> dict[str, Any]:
    # The backend stores names of environment variables, never raw service tokens.
    if body.kind == "telegram" and not body.config.get("channel"):
        raise HTTPException(422, "Telegram source config requires a channel")
    if body.kind in {"rest", "teldrive"} and not body.config.get("base_url"):
        raise HTTPException(422, "This source requires config.base_url")
    if body.kind == "json" and not (body.config.get("url") or body.config.get("file_path")):
        raise HTTPException(422, "JSON source requires config.url or config.file_path")
    if body.kind == "link" and not (body.config.get("url") or body.config.get("links")):
        raise HTTPException(422, "Link source requires config.url or config.links")
    if body.kind == "m3u" and not (body.config.get("url") or body.config.get("file_path")):
        raise HTTPException(422, "M3U source requires config.url or config.file_path")
    return db.create_source(body.name.strip(), body.kind, body.config, body.enabled)


@app.put("/api/sources/{source_id}", dependencies=[Depends(check_api_key)])
async def edit_source(source_id: str, body: SourceUpdate) -> dict[str, Any]:
    if body.kind == "telegram" and not body.config.get("channel"):
        raise HTTPException(422, "Telegram source config requires a channel")
    if body.kind in {"rest", "teldrive"} and not body.config.get("base_url"):
        raise HTTPException(422, "This source requires config.base_url")
    if body.kind == "json" and not (body.config.get("url") or body.config.get("file_path")):
        raise HTTPException(422, "JSON source requires config.url or config.file_path")
    if body.kind == "link" and not (body.config.get("url") or body.config.get("links")):
        raise HTTPException(422, "Link source requires config.url or config.links")
    if body.kind == "m3u" and not (body.config.get("url") or body.config.get("file_path")):
        raise HTTPException(422, "M3U source requires config.url or config.file_path")
    source = db.update_source(source_id, body.name.strip(), body.kind, body.config)
    if not source:
        raise HTTPException(404, "Source not found")
    return source


@app.delete("/api/sources/{source_id}", dependencies=[Depends(check_api_key)])
async def remove_source(source_id: str) -> dict[str, bool]:
    if not db.delete_source(source_id):
        raise HTTPException(404, "Source not found")
    return {"deleted": True}


@app.patch("/api/sources/{source_id}", dependencies=[Depends(check_api_key)])
async def toggle_source(source_id: str, body: SourceToggle) -> dict[str, Any]:
    source = db.set_source_enabled(source_id, body.enabled)
    if not source:
        raise HTTPException(404, "Source not found")
    return source


@app.post("/api/sources/{source_id}/test", dependencies=[Depends(check_api_key)])
async def test_source(source_id: str) -> dict[str, Any]:
    source = db.get_source(source_id)
    if not source:
        raise HTTPException(404, "Source not found")
    try:
        items = await adapter_for(source["kind"]).list_items(source)
        return {"ok": True, "items_found": len(items), "sample": [_public_item(item) for item in items[:3]]}
    except Exception as exc:
        if isinstance(exc, HTTPException):
            return {"ok": False, "status": exc.status_code, "error": exc.detail}
        return {"ok": False, "error": str(exc)}


@app.post("/api/sources/{source_id}/upload-json", dependencies=[Depends(check_api_key)])
async def upload_json(source_id: str, file: UploadFile = File(...)) -> dict[str, Any]:
    source = db.get_source(source_id)
    if not source or source["kind"] != "json":
        raise HTTPException(404, "JSON source not found")
    if not (file.filename or "").lower().endswith(".json"):
        raise HTTPException(415, "Upload a .json catalog file")
    content = await file.read(config.MAX_JSON_BYTES + 1)
    if len(content) > config.MAX_JSON_BYTES:
        raise HTTPException(413, "JSON catalog exceeds configured size limit")
    try:
        json.loads(content)
    except json.JSONDecodeError as exc:
        raise HTTPException(422, "Invalid JSON file") from exc
    imports_dir = config.DATA_DIR / "imports"
    imports_dir.mkdir(parents=True, exist_ok=True)
    safe_name = f"{uuid.uuid4().hex}.json"
    target = imports_dir / safe_name
    target.write_bytes(content)
    new_cfg = {**source["config"], "file_path": str(target), "url": None}
    db.update_source_config(source_id, new_cfg)
    return {"uploaded": True, "source_id": source_id, "filename": Path(file.filename).name}


@app.get("/api/app-config", dependencies=[Depends(check_api_key)])
async def get_app_config() -> dict[str, Any]:
    return {
        "gemini_available": bool(config.GEMINI_API_KEY),
        "gemini_model": config.GEMINI_MODEL,
        "transcode_enabled": config.TRANSCODE_ENABLED and bool(shutil.which(config.FFMPEG_BINARY)),
        "compressor_bot": config.TELEGRAM_COMPRESSOR_BOT or None,
        "max_json_bytes": config.MAX_JSON_BYTES,
    }


async def _collect_catalog(source_id: str | None = None) -> tuple[list[dict[str, Any]], list[dict[str, str]]]:
    sources = [s for s in db.list_sources() if s["enabled"] and (not source_id or s["id"] == source_id)]
    items: list[dict[str, Any]] = []
    warnings: list[dict[str, str]] = []
    for source in sources:
        try:
            items.extend(await adapter_for(source["kind"]).list_items(source))
        except Exception as exc:
            detail = exc.detail if isinstance(exc, HTTPException) else str(exc)
            warnings.append({"source_id": source["id"], "source_name": source["name"], "error": str(detail)})
    # De-duplicate repeated API rows but preserve the same media item across different sources.
    unique: dict[tuple[str, str], dict[str, Any]] = {}
    for item in items:
        unique[(str(item.get("source_id")), str(item.get("id")))] = item
    return list(unique.values()), warnings


def _public_item(item: dict[str, Any]) -> dict[str, Any]:
    # Do not expose signed upstream URLs; playback always goes through this API.
    return {key: value for key, value in item.items() if key not in {"external_url", "storage_hash"}}


def _public_tree(node: Any) -> Any:
    if isinstance(node, list):
        return [_public_tree(value) for value in node]
    if isinstance(node, dict):
        if "source_id" in node and "stream_url" in node:
            return _public_item(node)
        return {key: _public_tree(value) for key, value in node.items()}
    return node


@app.get("/api/catalog", dependencies=[Depends(check_api_key)])
async def get_catalog(
    q: str = Query(default="", max_length=160),
    source_id: str | None = None,
) -> dict[str, Any]:
    items, warnings = await _collect_catalog(source_id)
    ranked = score_items(items, q, config.CATALOG_LIMIT)
    public_items = [_public_item(item) for item in ranked]
    return {"items": public_items, "count": len(public_items), "warnings": warnings, "search_method": "offline_parser_and_scorer" if q else "catalog"}


@app.get("/api/catalog/tree", dependencies=[Depends(check_api_key)])
async def get_catalog_tree() -> dict[str, Any]:
    items, warnings = await _collect_catalog()
    return {"tree": _public_tree(virtual_tree(items)), "count": len(items), "warnings": warnings}


class DeepSearchRequest(BaseModel):
    query: str = Field(min_length=2, max_length=300)
    use_ai: bool = True


@app.post("/api/search/deep", dependencies=[Depends(check_api_key)])
async def deep_search(body: DeepSearchRequest) -> dict[str, Any]:
    items, warnings = await _collect_catalog()
    local = score_items(items, body.query, config.CATALOG_LIMIT)
    if not body.use_ai:
        public = [_public_item(item) for item in local]
        return {"items": public, "count": len(public), "method": "offline", "interpretation": "", "warnings": warnings}
    if not config.GEMINI_API_KEY:
        public = [_public_item(item) for item in local]
        return {"items": public, "count": len(public), "method": "offline_fallback", "interpretation": "Gemini is not configured; showing offline matches.", "warnings": warnings}
    ai = await gemini_rank(body.query, items)
    public = [_public_item(item) for item in ai["items"]]
    return {**ai, "items": public, "count": len(public), "warnings": warnings}


async def _transcode_response(upstream: StreamingResponse, quality: str) -> StreamingResponse:
    if not config.TRANSCODE_ENABLED or not shutil.which(config.FFMPEG_BINARY):
        raise HTTPException(501, "FFmpeg transcoding is unavailable on this backend")
    presets = {
        "480p": (480, "30", "96k"),
        "720p": (720, "27", "128k"),
        "1080p": (1080, "25", "160k"),
    }
    height, crf, audio_bitrate = presets[quality]
    process = await asyncio.create_subprocess_exec(
        config.FFMPEG_BINARY, "-hide_banner", "-loglevel", "error", "-i", "pipe:0",
        "-vf", f"scale=-2:min({height}\\,ih)", "-c:v", "libx264", "-preset", "ultrafast",
        "-crf", crf, "-c:a", "aac", "-b:a", audio_bitrate,
        "-f", "mpegts", "pipe:1",
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
    )

    async def feed_input() -> None:
        try:
            async for chunk in upstream.body_iterator:
                if process.stdin is None:
                    break
                process.stdin.write(chunk)
                await process.stdin.drain()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            if process.stdin:
                process.stdin.close()

    feeder = asyncio.create_task(feed_input())

    async def output() -> Any:
        try:
            while process.stdout:
                chunk = await process.stdout.read(64 * 1024)
                if not chunk:
                    break
                yield chunk
            await feeder
            await process.wait()
        finally:
            if not feeder.done():
                feeder.cancel()
            if process.returncode is None:
                process.kill()
                await process.wait()
            close = getattr(upstream.body_iterator, "aclose", None)
            if close:
                await close()

    return StreamingResponse(output(), media_type="video/mp2t", headers={
        "Cache-Control": "no-store", "Accept-Ranges": "none", "X-Transcoded-Quality": quality,
    })


@app.get("/api/stream/{source_id}/{item_id}", dependencies=[Depends(check_api_key)])
async def stream_item(
    source_id: str,
    item_id: str,
    request: Request,
    quality: str | None = Query(default=None),
):
    source = db.get_source(source_id)
    if not source or not source["enabled"]:
        raise HTTPException(404, "Source not found or disabled")
    if quality and quality not in {"480p", "720p", "1080p"}:
        raise HTTPException(422, "quality must be 480p, 720p or 1080p")
    # Transcoding is a sequential MPEG-TS stream; byte-range seeking is disabled for this path.
    if quality:
        upstream = await adapter_for(source["kind"]).stream(source, item_id, None)
        return await _transcode_response(upstream, quality)
    return await adapter_for(source["kind"]).stream(source, item_id, request.headers.get("range"))


@app.get("/api/progress", dependencies=[Depends(check_api_key)])
async def get_watch_progress() -> dict[str, Any]:
    return db.get_progress()


@app.put("/api/progress", dependencies=[Depends(check_api_key)])
async def put_watch_progress(body: ProgressUpdate) -> dict[str, bool]:
    db.save_progress(body.item_key, body.position_ms, body.duration_ms)
    return {"saved": True}
