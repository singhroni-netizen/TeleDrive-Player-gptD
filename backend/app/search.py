from __future__ import annotations

import json
import re
from collections import Counter
from typing import Any

import httpx
from fastapi import HTTPException

from . import config

STOP_WORDS = {
    "a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "that", "where",
    "is", "was", "it", "its", "from", "near", "about", "find", "show", "me", "movie", "film",
    "series", "episode", "season", "watch", "my", "some", "this", "by", "at", "as", "be",
}
QUALITY_RE = re.compile(r"(?i)\b(2160p|4k|uhd|1080p|720p|576p|480p|360p)\b")
CODEC_RE = re.compile(r"(?i)\b(x265|h\.265|h265|hevc|x264|h\.264|h264|av1|av01)\b")
EPISODE_RE = re.compile(r"(?i)\bS(\d{1,2})[ ._-]*E(\d{1,3})\b")
YEAR_RE = re.compile(r"\b(19\d{2}|20\d{2})\b")


def tokens(value: str) -> list[str]:
    return [x for x in re.findall(r"[a-z0-9]+", value.casefold()) if len(x) > 1 and x not in STOP_WORDS]


def parse_filename(value: str) -> dict[str, Any]:
    """Fast, deterministic filename parser. Never changes the original filename."""
    stem = re.sub(r"\.[a-z0-9]{2,5}$", "", value, flags=re.IGNORECASE)
    ep = EPISODE_RE.search(stem)
    year = YEAR_RE.search(stem)
    quality = QUALITY_RE.search(stem)
    codec = CODEC_RE.search(stem)
    title = stem
    for pattern in (EPISODE_RE, YEAR_RE, QUALITY_RE, CODEC_RE):
        match = pattern.search(title)
        if match:
            title = title[:match.start()] + " " + title[match.end():]
    title = re.sub(r"[._\[\](){}]+", " ", title)
    title = re.sub(r"\s+", " ", title).strip(" -_")
    series = ""
    if ep:
        series = re.sub(r"[._\[\](){}]+", " ", stem[:ep.start()])
        series = re.sub(r"\s+", " ", series).strip(" -_")
    return {
        "parsed_title": title or stem,
        "series": series or title or stem,
        "year": int(year.group(1)) if year else None,
        "season": int(ep.group(1)) if ep else None,
        "episode": int(ep.group(2)) if ep else None,
        "quality": quality.group(1).upper() if quality else None,
        "codec": codec.group(1).upper().replace(".", "") if codec else None,
    }


def score_items(items: list[dict[str, Any]], query: str, limit: int | None = None) -> list[dict[str, Any]]:
    """Offline metadata/token scorer (no embeddings and no network access)."""
    q = query.strip()
    if not q:
        return items[:limit or config.CATALOG_LIMIT]
    parsed = parse_filename(q)
    query_tokens = tokens(q)
    scored: list[tuple[float, dict[str, Any]]] = []
    for item in items:
        title = str(item.get("title") or "")
        filename = str(item.get("filename") or title)
        desc = str(item.get("description") or "")
        parsed_item = parse_filename(filename)
        haystack = f"{title} {filename} {desc} {item.get('source_name', '')} {item.get('quality', '')} {item.get('codec', '')}".casefold()
        title_low = f"{title} {parsed_item['parsed_title']}".casefold()
        score = 0.0
        for token in query_tokens:
            if token in title_low:
                score += 4.0 if token == title_low else 2.5
            elif token in haystack:
                score += 0.8
        if len(q) >= 4 and q.casefold() in haystack:
            score += 5.0
        # Metadata constraints are strong filters, not loose keyword matches.
        if parsed.get("year") is not None:
            score += 6 if item.get("year") == parsed["year"] else -3
        if parsed.get("season") is not None:
            score += 5 if item.get("season") == parsed["season"] else -2
        if parsed.get("episode") is not None:
            score += 5 if item.get("episode") == parsed["episode"] else -2
        if parsed.get("quality"):
            item_quality = str(item.get("quality") or parsed_item.get("quality") or "").upper()
            score += 2.5 if parsed["quality"] == item_quality else -0.5
        if parsed.get("codec"):
            item_codec = str(item.get("codec") or parsed_item.get("codec") or "").upper().replace(".", "")
            score += 2.5 if parsed["codec"] == item_codec else -0.5
        # A compact BM25-like title boost for multi-word name overlap.
        title_terms = tokens(title_low)
        overlap = len(set(query_tokens) & set(title_terms))
        if query_tokens:
            score += 2.0 * overlap / len(set(query_tokens))
        if score > 0:
            scored.append((score, item))
    scored.sort(key=lambda row: (-row[0], str(row[1].get("title") or "").casefold()))
    return [item for _, item in scored[:limit or config.CATALOG_LIMIT]]


def virtual_tree(items: list[dict[str, Any]]) -> dict[str, Any]:
    """Create a presentation-only tree; source storage paths are never modified."""
    movies: dict[str, list[dict[str, Any]]] = {}
    shows: dict[str, dict[int, list[dict[str, Any]]]] = {}
    other: list[dict[str, Any]] = []
    for item in items:
        if not item.get("kind") == "video":
            other.append(item)
            continue
        filename = str(item.get("filename") or item.get("title") or "")
        parsed = parse_filename(filename)
        season = item.get("season") or parsed.get("season")
        episode = item.get("episode") or parsed.get("episode")
        if season is not None:
            series = str(item.get("series") or parsed.get("series") or item.get("title") or "Unknown Series")
            series = re.sub(r"\b(19\d{2}|20\d{2})\b", "", series).strip(" -_") or "Unknown Series"
            shows.setdefault(series, {}).setdefault(int(season), []).append(item)
        else:
            movie_title = str(parsed.get("parsed_title") or item.get("title") or filename)
            year = item.get("year") or parsed.get("year")
            key = f"{movie_title} ({year})" if year else movie_title
            movies.setdefault(key, []).append(item)
    show_rows = []
    for name, seasons in sorted(shows.items(), key=lambda pair: pair[0].casefold()):
        season_rows = []
        for number, entries in sorted(seasons.items()):
            entries.sort(key=lambda x: (x.get("episode") or 0, str(x.get("title") or "").casefold()))
            season_rows.append({"name": f"Season {number:02d}", "season": number, "items": entries})
        show_rows.append({"name": name, "seasons": season_rows})
    return {
        "movies": [{"name": k, "items": v} for k, v in sorted(movies.items(), key=lambda pair: pair[0].casefold())],
        "tv_shows": show_rows,
        "other_files": sorted(other, key=lambda x: str(x.get("title") or "").casefold()),
    }


async def gemini_rank(query: str, items: list[dict[str, Any]]) -> dict[str, Any]:
    if not config.GEMINI_API_KEY:
        raise HTTPException(503, "Gemini search is not configured. Set GEMINI_API_KEY on the backend.")
    candidates = [
        {
            "id": str(item.get("id")), "source_id": str(item.get("source_id")),
            "title": str(item.get("title") or ""), "year": item.get("year"),
            "season": item.get("season"), "episode": item.get("episode"),
            "description": str(item.get("description") or "")[:240],
        }
        for item in items[:config.GEMINI_CANDIDATE_LIMIT]
    ]
    prompt = (
        "You are a media-catalog retrieval assistant. Match the user's natural-language description "
        "only against the supplied catalog candidates. Do not invent titles or IDs. Return valid JSON "
        "with keys ranked_ids (array of objects containing source_id, id, confidence from 0 to 1, "
        "reason) and interpretation (short string). Order best match first. Return an empty array when "
        "there is no defensible match.\n\n"
        f"User query: {query}\nCatalog candidates: {json.dumps(candidates, ensure_ascii=False)}"
    )
    url = f"https://generativelanguage.googleapis.com/v1beta/models/{config.GEMINI_MODEL}:generateContent"
    try:
        async with httpx.AsyncClient(timeout=35) as client:
            response = await client.post(
                url,
                params={"key": config.GEMINI_API_KEY},
                json={
                    "contents": [{"role": "user", "parts": [{"text": prompt}]}],
                    "generationConfig": {"temperature": 0.1, "responseMimeType": "application/json"},
                },
            )
            response.raise_for_status()
            payload = response.json()
        raw = payload["candidates"][0]["content"]["parts"][0]["text"]
        result = json.loads(raw)
        by_key = {(str(x.get("source_id")), str(x.get("id"))): x for x in items}
        ranked = []
        for row in result.get("ranked_ids", []):
            key = (str(row.get("source_id")), str(row.get("id")))
            if key in by_key:
                ranked.append({**by_key[key], "ai_confidence": row.get("confidence"), "ai_reason": row.get("reason")})
        return {"items": ranked, "interpretation": str(result.get("interpretation") or ""), "method": "gemini"}
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(502, f"Gemini deep search failed: {exc}") from exc
