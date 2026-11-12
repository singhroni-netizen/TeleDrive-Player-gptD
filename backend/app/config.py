from __future__ import annotations

import os
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent.parent
DATA_DIR = Path(os.getenv("DATA_DIR", APP_DIR / "data")).resolve()
DATA_DIR.mkdir(parents=True, exist_ok=True)
DB_PATH = Path(os.getenv("DB_PATH", DATA_DIR / "teledrive.db")).resolve()
API_KEY = os.getenv("APP_API_KEY", "").strip()
TELEGRAM_API_ID = os.getenv("TELEGRAM_API_ID", "").strip()
TELEGRAM_API_HASH = os.getenv("TELEGRAM_API_HASH", "").strip()
TELEGRAM_SESSION = os.getenv("TELEGRAM_SESSION", "").strip()
TELEGRAM_SESSION_FILE = Path(os.getenv("TELEGRAM_SESSION_FILE", DATA_DIR / "telegram.session")).resolve()
REQUEST_TIMEOUT = float(os.getenv("REQUEST_TIMEOUT", "45"))
MAX_JSON_BYTES = int(os.getenv("MAX_JSON_BYTES", str(25 * 1024 * 1024)))
CATALOG_LIMIT = int(os.getenv("CATALOG_LIMIT", "500"))
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "").strip()
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-3.5-flash-lite").strip()
GEMINI_CANDIDATE_LIMIT = int(os.getenv("GEMINI_CANDIDATE_LIMIT", "250"))
TELEGRAM_COMPRESSOR_BOT = os.getenv("TELEGRAM_COMPRESSOR_BOT", "").strip().lstrip("@")
TRANSCODE_ENABLED = os.getenv("TRANSCODE_ENABLED", "true").lower() in {"1", "true", "yes"}
FFMPEG_BINARY = os.getenv("FFMPEG_BINARY", "ffmpeg").strip()
CORS_ORIGINS = [x.strip() for x in os.getenv("CORS_ORIGINS", "*").split(",") if x.strip()]
