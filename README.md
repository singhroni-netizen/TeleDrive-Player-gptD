# TeleDrive Player

A self-hosted, single-user media catalog and streaming player for **Android and Windows**. It creates a virtual Netflix-style library from cloud locations and media indexes without renaming, moving, or reorganizing the original files.

> **Project status:** working MVP / deployment starter. The backend adapters, API, Flutter screens, playback controls, and CI workflow are included. A real deployment still needs your own Telegram credentials, provider endpoints, API keys, and a machine to host the backend. Provider-specific Teldrive mappings and device playback should be acceptance-tested against your server and devices before relying on them.

## What is included

- Flutter client with an OLED-black interface, hero feature, poster rows, filters, virtual folders, and Continue Watching.
- `media_kit` / `libmpv` native player with seeking, playback speed, audio/subtitle selection, screen brightness gesture, volume boost, A–B repeat, sleep timer, aspect fit/fill, and screen lock.
- FastAPI backend with SQLite source registry and cross-device watch progress.
- Modular source adapters: Telegram MTProto, Teldrive-compatible REST API, JSON catalog, generic REST API, direct HTTP/HTTPS links, and M3U playlist.
- Filename parser for year, SxxExxx, quality and codec tags; offline local scoring; optional Gemini natural-language search.
- Byte-range HTTP proxy for supported upstreams and optional FFmpeg 480p/720p/1080p transcode path.
- Optional Telegram compressor-bot shortcut for files larger than 800 MB.
- GitHub Actions workflow to build Android APKs and a Windows release bundle.

## Architecture

```text
Flutter Android / Windows
          |
          | HTTPS + X-API-Key
          v
FastAPI catalog + playback gateway
          |
          +-- Telegram MTProto (Telethon user session)
          +-- Teldrive API adapter
          +-- JSON file / remote JSON URL
          +-- Generic REST API (dotted field mapping)
          +-- Direct HTTP / HTTPS file links
          +-- M3U playlist
          |
          +-- SQLite: sources + watch progress
          +-- Local parser + offline scorer
          +-- Optional Gemini catalog ranking
          +-- Optional FFmpeg downscale proxy
          v
       libmpv player
```

The Flutter client never receives the Telegram session string, Teldrive token, Gemini key, or provider authorization headers. Put secrets in the backend environment and refer to them from source definitions using `token_env` or `cookie_env`.

## 1. Run the backend with Docker

Install Docker Desktop (Windows) or Docker Engine + Compose (Linux).

```bash
# from the repository root
cp .env.example .env
```

On Windows PowerShell:

```powershell
Copy-Item .env.example .env
```

Edit `.env` and replace `APP_API_KEY` with a long random secret. Set only the integrations you intend to use. Then start the service:

```bash
docker compose up -d --build
docker compose logs -f teledrive-api
```

Health check: `http://localhost:8000/health`
API documentation: `http://localhost:8000/docs`

The `data/` directory is mounted persistently and holds the SQLite database, imported JSON catalogs, and an optional Telethon session file. Back it up. The backend container includes FFmpeg for downscaling.

**Production:** expose the API only through HTTPS, keep the backend API key private, restrict inbound network access, and set `CORS_ORIGINS` to your actual client origins. Do not publish the raw port to the public internet without a TLS reverse proxy and firewall policy. The API key is a single-user access gate, not a multi-user identity system.

## 2. Connect the Flutter client

Install the Flutter stable SDK and Android Studio (for Android builds) or Visual Studio with the Desktop development with C++ workload (for Windows builds).

Generate the native runner folders once:

```bash
python scripts/bootstrap_flutter.py
```

Resolve dependencies and run:

```bash
cd client
flutter pub get
flutter run -d windows
# or select an Android device/emulator
flutter run -d android
```

Open **Settings** in the app and enter the backend URL and the same `APP_API_KEY`:

- Windows on the same computer: `http://127.0.0.1:8000`
- Android emulator: `http://10.0.2.2:8000`
- Physical Android on the same LAN: `http://YOUR_SERVER_LAN_IP:8000`
- Remote access: your HTTPS backend URL

For Android, the app's default emulator URL is `10.0.2.2`. A physical device must use the reachable LAN IP or HTTPS hostname; `localhost` refers to the phone itself.

## 3. Configure data sources in the app

Go to **Data Sources → Add Source**. Source configs are JSON so field mapping can be adjusted without changing Flutter code. Use the **Test** icon after creating a source.

### Telegram channel or group (MTProto)

The backend uses a Telegram user session through Telethon. This is intentionally not based on the Bot API's smaller file-download limit. The logged-in Telegram account must have access to each channel/group.

1. Obtain `TELEGRAM_API_ID` and `TELEGRAM_API_HASH` from [my.telegram.org](https://my.telegram.org).
2. Install backend dependencies locally:

   ```powershell
   cd backend
   py -m venv .venv
   .\.venv\Scripts\Activate.ps1
   pip install -r requirements.txt
   $env:TELEGRAM_API_ID="your_api_id"
   $env:TELEGRAM_API_HASH="your_api_hash"
   python scripts_create_telegram_session.py
   ```

3. Complete Telegram's login prompt. Copy the printed `TELEGRAM_SESSION` into the root `.env` file. Treat it like a password.
4. Restart the backend container. Add a source with this config:

   ```json
   { "channel": "@your_channel", "limit": 500 }
   ```

A private channel can be specified by a channel ID only when the session account can resolve and access it. The channel is never modified by the app.

### Teldrive

Teldrive is a self-hosted Telegram-backed cloud-storage service with its own API and OpenAPI reference. Add a source using the URL of **your Teldrive instance**, and store the API key in the backend environment. The starter mapping uses the `X-Api-Key` header, `/api/files?page=1&order=asc&sort=name&path=/`, a `files` response array, and snake_case metadata such as `mime_type`. For playback it uses Teldrive's file-name route `/api/files/{id}/{name}?hash={hash}&download=1`, forwarding HTTP Range requests for seeking. The Teldrive project's logged requests show this listing shape and file-name download route, while the Teldrive Rclone backend confirms the `X-Api-Key` header and the `files`/`mime_type` metadata shape. These integrations can vary by release, so check your instance's OpenAPI reference and override the endpoint, query parameters, response path, and fields where needed.

Example starter mapping:

```json
{
  "base_url": "https://your-teldrive-host",
  "token_env": "TELDRIVE_TOKEN",
  "auth_header": "X-Api-Key",
  "auth_prefix": "",
  "list_path": "/api/files",
  "items_path": "files",
  "hash_field": "hash",
  "download_path": "/api/files/{id}/{name}?hash={hash}&download=1",
  "list_params": { "page": 1, "order": "asc", "sort": "name", "path": "/" },
  "type_field": "type",
  "id_field": "id",
  "title_field": "name",
  "mime_field": "mime_type",
  "size_field": "size"
}
```

If your Teldrive deployment uses another auth mechanism, header name, pagination shape, response envelope, or endpoint, change the mapping and/or the environment variable named by `token_env`. For an older server whose stream route is `/api/files/{id}/content`, set `download_path` to that template; the backend will use the legacy route without requiring the file hash. The backend accepts common `items` and `files` response arrays as a fallback, but use the exact `items_path` from your instance where possible. Do not assume every product called TeleDrive exposes the same API.

### JSON catalog (local file or URL)

A JSON source can read a URL or an uploaded local `.json` file. Local files are stored under backend `data/imports/`. Expected starter shape:

```json
{
  "items": [
    {
      "id": "movie-001",
      "title": "Example Film (2024).mkv",
      "url": "https://your-storage.example/video.mp4",
      "mime_type": "video/x-matroska",
      "size": 734003200,
      "poster": "https://your-cdn.example/poster.jpg",
      "description": "Optional description"
    }
  ]
}
```

The source editor supports `items_path`, `id_field`, `title_field`, and `url_field`. For nested APIs, use dotted paths such as `data.files` or `result.items.0`.

### Generic REST API

The REST adapter accepts a list endpoint and configurable JSON field mapping:

```json
{
  "base_url": "https://api.example.com",
  "list_path": "/media",
  "items_path": "data.items",
  "token_env": "MEDIA_API_TOKEN",
  "auth_header": "Authorization",
  "auth_prefix": "Bearer ",
  "id_field": "id",
  "title_field": "file_name",
  "url_field": "stream_url",
  "mime_field": "mime_type",
  "size_field": "size",
  "poster_field": "poster",
  "description_field": "description",
  "year_field": "year",
  "season_field": "season",
  "episode_field": "episode"
}
```

Supported mapping fields: `id_field`, `title_field`, `url_field`, `mime_field`, `size_field`, `poster_field`, `description_field`, `year_field`, `season_field`, `episode_field`, `series_field`, `quality_field`, `codec_field`, `duration_field`, and `date_field`. You may set `search_param` to the query parameter that your API accepts. For APIs that provide a download endpoint instead of a URL field, set `download_path` with `{id}` as the item ID placeholder.

For private APIs, set the real token in `.env` (for example `MEDIA_API_TOKEN=...`) and reference only its variable name in the source. `headers` is available for non-secret/static custom headers; do not put secrets directly in source JSON.

### Direct links and M3U

A direct-link source accepts one URL or a `links` array:

```json
{
  "links": [
    { "title": "Example Film", "url": "https://cdn.example/film.mp4", "mime_type": "video/mp4", "size": 500000000 },
    { "title": "Another Film", "url": "https://cdn.example/another.mkv" }
  ]
}
```

M3U sources accept a remote `.m3u` playlist URL or a local file inside the backend data directory. HLS `.m3u8` URLs can also be added as direct links when the upstream supports HTTP access. Providers requiring special cookies or authorization headers should use `headers`, `token_env`, or `cookie_env` in the source config.

## 4. Search and catalog organization

- **Tier 1:** instant filename parsing for year, season/episode, quality (`480p` through `4K`), and codec (`HEVC`, `x265`, `AV1`, etc.).
- **Tier 2:** offline title/description/token scoring runs on the backend CPU. This is a lightweight lexical scorer, not a downloaded embedding model.
- **Tier 3:** the Deep Search button sends the query and a limited set of catalog metadata (IDs, titles, years, episode numbers and short descriptions) to Gemini, then validates returned IDs against the local catalog. Stream URLs and provider secrets are not sent. Configure `GEMINI_API_KEY` and optionally `GEMINI_MODEL` in `.env`.

Default Gemini model is `gemini-3.5-flash-lite` for cost-efficient catalog matching. Model IDs change over time; choose a currently available model for your Google AI Studio/API account. Without a Gemini key, Deep Search falls back to local search.

The **Virtual Folders** view groups movies, shows, seasons and episodes at presentation time. It does not create folders or move cloud files.

## 5. Player and data saver

The player includes the libmpv-backed playback surface, play/pause, seek bar, ±10-second double tap, left-side brightness drag, right-side volume drag, volume boost up to 200%, press-and-hold 2× playback, audio-track selection, embedded subtitle selection, external subtitle URL (`.srt` / `.vtt`), speed selection from 0.25× to 3×, A–B loop, sleep timer, screen lock and fit/fill toggle.

Enable **Low-data streaming (480p)** in Settings to append `?quality=480p` to playback requests. The backend uses FFmpeg to produce an MPEG-TS stream. This uses server CPU and currently operates sequentially without byte-range seeking; turn it off for normal seeking and full-resolution playback. The 720p and 1080p quality values are available on the API for clients that expose them.

Set `TELEGRAM_COMPRESSOR_BOT=your_bot_username` to show a shortcut for media larger than 800 MB. The shortcut opens the configured bot in Telegram. Telegram does not permit this app to silently forward a private cloud message through a bot deep link, so the user must manually forward the original post/file to the bot.

## 6. GitHub builds

Create an empty GitHub repository, then from the project root:

```bash
git init
git add .
git commit -m "Initial TeleDrive Player app"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/teledrive-player.git
git push -u origin main
```

The included `.github/workflows/ci.yml` runs backend unit tests and builds:

- Android split APKs
- Windows release bundle ZIP

Download build artifacts from the repository's **Actions → CI and app builds → Artifacts**. Push a new commit to build again.

**GitHub Pages is not a backend host.** It can host static web assets, but it cannot run the Telegram MTProto client, SQLite source registry, or streaming proxy. Keep the backend running on your own PC, NAS, home server, or VPS. The GitHub workflow builds the client applications only.

## 7. Local backend test

```bash
cd backend
python -m venv .venv
# activate the virtual environment, then:
pip install -r requirements.txt
python -m unittest discover -s tests -v
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

When running outside Docker, export the environment values from `.env` in your shell before starting Uvicorn. Do not commit `.env`, Telegram session files, SQLite databases, or API keys.

## Limitations / planned hardening

- Teldrive's endpoint and response shape must be confirmed against the OpenAPI schema of the exact Teldrive server being used; the adapter exposes overrides for this.
- The backend is designed for one trusted user. It does not currently implement multi-user accounts, per-user access control, or an OAuth login flow.
- FFmpeg downscaling is CPU intensive and disables seeking in this first implementation. HLS segment-based adaptive transcoding would be a more advanced next step.
- HLS playlists hosted on third-party servers may require manifest rewriting when segment URLs are relative or authorization is scoped to the playlist host; test those links against your provider.
- Device-specific HDR, 10-bit HEVC, Dolby audio, hardware decode and thermal behavior depend on the device's native decoder/driver. Validate 4K media on the target Android handset and Windows PC.
- An actual GitHub push requires access to your GitHub account; this archive is ready to upload/push but has not been published to a remote repository from this session.

## License

MIT. Third-party media libraries retain their own licenses and notices. Users are responsible for accessing and streaming media they are authorized to use.
