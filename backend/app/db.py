from __future__ import annotations

import json
import sqlite3
import uuid
from contextlib import contextmanager
from typing import Any

from .config import DB_PATH


def init_db() -> None:
    DB_PATH.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(DB_PATH) as conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS sources (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            config_json TEXT NOT NULL,
            enabled INTEGER NOT NULL DEFAULT 1,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )""")
        conn.execute("""CREATE TABLE IF NOT EXISTS watch_progress (
            item_key TEXT PRIMARY KEY,
            position_ms INTEGER NOT NULL DEFAULT 0,
            duration_ms INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )""")
        conn.commit()


@contextmanager
def connect():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def create_source(name: str, kind: str, config: dict[str, Any], enabled: bool = True) -> dict[str, Any]:
    source_id = str(uuid.uuid4())
    with connect() as conn:
        conn.execute(
            "INSERT INTO sources(id,name,kind,config_json,enabled) VALUES(?,?,?,?,?)",
            (source_id, name, kind, json.dumps(config), int(enabled)),
        )
    return get_source(source_id)


def get_source(source_id: str) -> dict[str, Any] | None:
    with connect() as conn:
        row = conn.execute("SELECT * FROM sources WHERE id = ?", (source_id,)).fetchone()
    return _source_dict(row) if row else None


def list_sources() -> list[dict[str, Any]]:
    with connect() as conn:
        rows = conn.execute("SELECT * FROM sources ORDER BY created_at DESC").fetchall()
    return [_source_dict(row) for row in rows]


def delete_source(source_id: str) -> bool:
    with connect() as conn:
        cur = conn.execute("DELETE FROM sources WHERE id = ?", (source_id,))
    return cur.rowcount > 0


def set_source_enabled(source_id: str, enabled: bool) -> dict[str, Any] | None:
    with connect() as conn:
        conn.execute("UPDATE sources SET enabled = ? WHERE id = ?", (int(enabled), source_id))
    return get_source(source_id)


def update_source_config(source_id: str, config: dict[str, Any]) -> None:
    with connect() as conn:
        conn.execute("UPDATE sources SET config_json = ? WHERE id = ?", (json.dumps(config), source_id))


def update_source(source_id: str, name: str, kind: str, config: dict[str, Any]) -> dict[str, Any] | None:
    with connect() as conn:
        cur = conn.execute("UPDATE sources SET name = ?, kind = ?, config_json = ? WHERE id = ?",
                           (name, kind, json.dumps(config), source_id))
        if cur.rowcount == 0:
            return None
    return get_source(source_id)


def save_progress(item_key: str, position_ms: int, duration_ms: int) -> None:
    with connect() as conn:
        conn.execute(
            """INSERT INTO watch_progress(item_key,position_ms,duration_ms) VALUES(?,?,?)
            ON CONFLICT(item_key) DO UPDATE SET position_ms=excluded.position_ms,
            duration_ms=excluded.duration_ms, updated_at=CURRENT_TIMESTAMP""",
            (item_key, max(0, position_ms), max(0, duration_ms)),
        )


def get_progress() -> dict[str, dict[str, int]]:
    with connect() as conn:
        rows = conn.execute("SELECT item_key,position_ms,duration_ms FROM watch_progress").fetchall()
    return {r["item_key"]: {"position_ms": r["position_ms"], "duration_ms": r["duration_ms"]} for r in rows}


def _source_dict(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "id": row["id"], "name": row["name"], "kind": row["kind"],
        "config": json.loads(row["config_json"]), "enabled": bool(row["enabled"]),
        "created_at": row["created_at"],
    }
