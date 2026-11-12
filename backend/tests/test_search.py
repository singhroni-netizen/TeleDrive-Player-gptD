import unittest

from app.search import parse_filename, score_items, virtual_tree


class SearchTests(unittest.TestCase):
    def test_filename_parser_extracts_release_metadata(self):
        parsed = parse_filename("Arrival.2016.1080p.BluRay.x265.mkv")
        self.assertEqual(parsed["year"], 2016)
        self.assertEqual(parsed["quality"], "1080P")
        self.assertEqual(parsed["codec"], "X265")
        self.assertIn("Arrival", parsed["parsed_title"])

    def test_filename_parser_extracts_episode(self):
        parsed = parse_filename("The.Expanse.S03E06.720p.HEVC.mkv")
        self.assertEqual(parsed["season"], 3)
        self.assertEqual(parsed["episode"], 6)
        self.assertEqual(parsed["quality"], "720P")

    def test_offline_search_ranks_title_match(self):
        items = [
            {"id": "1", "title": "Arrival", "filename": "Arrival.2016.1080p.mkv", "year": 2016, "kind": "video"},
            {"id": "2", "title": "The Martian", "filename": "The.Martian.2015.1080p.mkv", "year": 2015, "kind": "video"},
        ]
        ranked = score_items(items, "Arrival 2016 1080p")
        self.assertEqual(ranked[0]["id"], "1")

    def test_virtual_tree_groups_seasons(self):
        items = [
            {"id": "a", "title": "Orbit S01E01", "filename": "Orbit.S01E01.mkv", "kind": "video", "season": 1, "episode": 1, "series": "Orbit"},
            {"id": "b", "title": "Orbit S01E02", "filename": "Orbit.S01E02.mkv", "kind": "video", "season": 1, "episode": 2, "series": "Orbit"},
            {"id": "c", "title": "Other Film (2020)", "filename": "Other.Film.2020.mkv", "kind": "video", "year": 2020},
            {"id": "d", "title": "notes.pdf", "filename": "notes.pdf", "kind": "file"},
        ]
        tree = virtual_tree(items)
        self.assertEqual(tree["tv_shows"][0]["name"], "Orbit")
        self.assertEqual(len(tree["tv_shows"][0]["seasons"][0]["items"]), 2)
        self.assertEqual(len(tree["movies"]), 1)
        self.assertEqual(len(tree["other_files"]), 1)


if __name__ == "__main__":
    unittest.main()
