import asyncio
import unittest
from unittest.mock import AsyncMock, patch
from app.sources import (
    M3uAdapter, TeldriveAdapter, _extract_rows, _normalize_rest_row, clean_item, dotted_get, parse_range,
)
from fastapi import HTTPException


class SourceUtilityTests(unittest.TestCase):
    def setUp(self):
        self.source = {"id": "source-1", "name": "Test source"}

    def test_nested_items_path(self):
        payload = {"data": {"items": [{"id": 1}, {"id": 2}]}}
        self.assertEqual(dotted_get(payload, "data.items.1.id"), 2)

    def test_extract_rows_accepts_teldrive_files_envelope(self):
        payload = {"files": [{"id": "f1", "name": "Film.mkv"}]}
        self.assertEqual(_extract_rows(payload, "files", "REST")[0]["id"], "f1")

    def test_extract_rows_falls_back_to_common_envelope(self):
        payload = {"data": {"files": [{"id": "f2"}]}}
        self.assertEqual(_extract_rows(payload, "items", "REST")[0]["id"], "f2")

    def test_folder_rows_are_not_catalogued(self):
        normalized = _normalize_rest_row(
            self.source, {"id": "folder-1", "name": "Movies", "type": "folder"},
            {"type_field": "type", "id_field": "id", "title_field": "name"}, "0",
        )
        self.assertIsNone(normalized)

    def test_teldrive_defaults_use_api_key_and_snake_case_metadata(self):
        source = {"config": {"base_url": "https://td.example", "token_env": "TD_KEY"}}
        cfg = TeldriveAdapter()._config(source)
        self.assertEqual(cfg["auth_header"], "X-Api-Key")
        self.assertEqual(cfg["mime_field"], "mime_type")
        self.assertEqual(cfg["items_path"], "files")
        self.assertIn("{hash}", cfg["download_path"])

    def test_teldrive_stream_formats_file_name_and_hash_url(self):
        source = {"id": "td", "name": "td", "config": {"base_url": "https://td.example"}}
        adapter = TeldriveAdapter()
        metadata = {"id": "id/1", "name": "A Film.mkv", "hash": "h123"}
        with patch.object(adapter, "_get_file_metadata", new=AsyncMock(return_value=metadata)), \
             patch("app.sources.proxy_http_stream", new=AsyncMock(return_value="stream")) as proxy:
            result = asyncio.run(adapter.stream(source, "id/1", "bytes=0-99"))
        self.assertEqual(result, "stream")
        args = proxy.await_args.args
        self.assertEqual(args[0], "https://td.example/api/files/id%2F1/A%20Film.mkv?hash=h123&download=1")
        self.assertEqual(args[2], "bytes=0-99")

    def test_teldrive_stream_falls_back_to_list_when_detail_route_is_missing(self):
        source = {"id": "td", "name": "td", "config": {"base_url": "https://td.example"}}
        adapter = TeldriveAdapter()
        rows = [{"id": "abc", "title": "Film.mkv", "filename": "Film.mkv", "storage_hash": "hash-1"}]
        with patch.object(adapter, "_get_file_metadata", new=AsyncMock(return_value={})), \
             patch("app.sources.RestAdapter.list_items", new=AsyncMock(return_value=rows)), \
             patch("app.sources.proxy_http_stream", new=AsyncMock(return_value="stream")) as proxy:
            result = asyncio.run(adapter.stream(source, "abc", "bytes=0-10"))
        self.assertEqual(result, "stream")
        self.assertIn("/abc/Film.mkv?hash=hash-1&download=1", proxy.await_args.args[0])

    def test_m3u_relative_media_url_resolves_against_playlist(self):
        class FixtureM3uAdapter(M3uAdapter):
            async def _text(self, cfg):
                return '#EXTM3U\n#EXTINF:-1 tvg-id="movie-1",Example Film\nmedia/film.mp4\n'

        source = {
            "id": "m3u-1", "name": "Remote playlist", "kind": "m3u",
            "config": {"url": "https://media.example/lists/movies.m3u"},
        }
        rows = asyncio.run(FixtureM3uAdapter().list_items(source))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["external_url"], "https://media.example/lists/media/film.mp4")

    def test_infers_series_metadata(self):
        item = clean_item(self.source, "x", "The Example Show S02E07 1080p.mkv", mime_type="video/x-matroska")
        self.assertEqual(item["season"], 2)
        self.assertEqual(item["episode"], 7)
        self.assertEqual(item["kind"], "video")

    def test_infers_year(self):
        item = clean_item(self.source, "x", "Example Film (2023).mp4")
        self.assertEqual(item["year"], 2023)

    def test_full_range(self):
        self.assertEqual(parse_range(None, 100), (0, 99, False))

    def test_open_ended_range(self):
        self.assertEqual(parse_range("bytes=50-", 100), (50, 99, True))

    def test_suffix_range(self):
        self.assertEqual(parse_range("bytes=-10", 100), (90, 99, True))

    def test_unsatisfiable_range(self):
        with self.assertRaises(HTTPException):
            parse_range("bytes=100-", 100)


if __name__ == "__main__":
    unittest.main()
