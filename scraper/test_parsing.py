"""Tests for the chunk-splitting and concurrent-parse helpers in scraper.py.

A studio's oversized page text is split into independent segments and parsed by several
Haiku calls at once. Concurrency here is safe only because results are reassembled in
submission order — both callers dedup by _class_identity_key keeping the FIRST match, so
if completion order leaked through, which duplicate survives would depend on network
timing rather than on the page. That is the property these tests pin down, since it
would otherwise fail silently and only on slow days.

Run with either:
    python3 -m unittest test_parsing
    python3 -m pytest test_parsing.py   # if pytest is installed
"""
import sys
import time
import types
import unittest
from unittest.mock import patch


def _stub(name):
    if name not in sys.modules:
        sys.modules[name] = types.ModuleType(name)


_stub("requests")
_stub("anthropic")
sys.modules["anthropic"].Anthropic = lambda *a, **k: None
_stub("playwright")
_pw = types.ModuleType("playwright.sync_api")
_pw.sync_playwright = lambda *a, **k: None
sys.modules["playwright.sync_api"] = _pw

_db = types.ModuleType("db")
_db.get_or_create_location = lambda *a, **k: None
_db.replace_future_classes = lambda *a, **k: None
_db.get_default_location = lambda *a, **k: None
_db.fetch_window_class_ids = lambda *a, **k: set()
_db.fetch_window_rows = lambda *a, **k: []
sys.modules["db"] = _db

import scraper  # noqa: E402  (import after stubs are in place)


class TestSplitChunks(unittest.TestCase):
    def test_short_text_is_one_chunk(self):
        self.assertEqual(scraper._split_chunks("just a little text"), ["just a little text"])

    def test_every_chunk_is_within_the_limit(self):
        text = "\n\n".join(f"para {i} " + "x" * 400 for i in range(60))
        for chunk in scraper._split_chunks(text):
            self.assertLessEqual(len(chunk), scraper._CHUNK_LIMIT)

    def test_splits_on_paragraph_boundaries_not_mid_class(self):
        # Each paragraph is one class's text block; none may be cut in half.
        paras = [f"CLASS {i}\ninstructor {i}\n2026-09-0{i % 9} 19:00" for i in range(300)]
        text = "\n\n".join(paras)
        chunks = scraper._split_chunks(text)
        self.assertGreater(len(chunks), 1)
        for p in paras:
            self.assertTrue(any(p in c for c in chunks), f"paragraph split across chunks: {p!r}")

    def test_no_empty_chunks(self):
        text = "a" * 100 + "\n\n\n\n" + "b" * 100 + "\n\n" + "c" * 6000
        self.assertTrue(all(c.strip() for c in scraper._split_chunks(text)))

    def test_text_with_no_blank_lines_still_splits(self):
        # Falls back to a single-newline boundary when no blank line is in range.
        text = "\n".join("line " + "y" * 90 for _ in range(200))
        chunks = scraper._split_chunks(text)
        self.assertGreater(len(chunks), 1)
        for chunk in chunks:
            self.assertLessEqual(len(chunk), scraper._CHUNK_LIMIT)


class TestParseSegments(unittest.TestCase):
    def test_empty_input(self):
        self.assertEqual(scraper._parse_segments([], "s", "S"), [])

    def test_results_follow_submission_order_not_completion_order(self):
        # The first segment is made the SLOWEST, so anything that collected results as
        # they completed (e.g. as_completed) would return them reversed.
        segments = ["first", "second", "third", "fourth"]
        delays = {"first": 0.20, "second": 0.02, "third": 0.01, "fourth": 0.0}

        def fake_parse(text, studio_id, studio_name):
            time.sleep(delays[text])
            return [{"title": text}]

        with patch.object(scraper, "_parse_raw", fake_parse):
            got = scraper._parse_segments(segments, "s", "S")
        self.assertEqual([g[0]["title"] for g in got], segments)

    def test_one_result_list_per_segment(self):
        with patch.object(scraper, "_parse_raw", lambda t, a, b: [{"title": t}, {"title": t}]):
            got = scraper._parse_segments(["a", "b", "c"], "s", "S")
        self.assertEqual(len(got), 3)
        self.assertTrue(all(len(g) == 2 for g in got))

    def test_a_failing_segment_yields_empty_and_spares_the_others(self):
        def fake_parse(text, studio_id, studio_name):
            if text == "bad":
                raise RuntimeError("boom")
            return [{"title": text}]

        with patch.object(scraper, "_parse_raw", fake_parse):
            got = scraper._parse_segments(["ok1", "bad", "ok2"], "s", "S")
        self.assertEqual(got[0], [{"title": "ok1"}])
        self.assertEqual(got[1], [])
        self.assertEqual(got[2], [{"title": "ok2"}])

    def test_single_segment_failure_is_also_contained(self):
        def boom(*a, **k):
            raise RuntimeError("boom")

        with patch.object(scraper, "_parse_raw", boom):
            self.assertEqual(scraper._parse_segments(["only"], "s", "S"), [[]])

    def test_segments_run_concurrently(self):
        # Four segments that each sleep 0.15s finish in well under the 0.6s they would
        # take one after another — the whole point of the change.
        def slow(text, studio_id, studio_name):
            time.sleep(0.15)
            return [{"title": text}]

        with patch.object(scraper, "_parse_raw", slow):
            t0 = time.time()
            scraper._parse_segments(["a", "b", "c", "d"], "s", "S")
            elapsed = time.time() - t0
        self.assertLess(elapsed, 0.45)


class TestChunkedParseDedup(unittest.TestCase):
    """_parse_raw's chunking branch keeps the first of any duplicate across chunks; that
    behaviour must survive the segments being parsed concurrently."""

    def test_duplicates_across_chunks_keep_the_first(self):
        dupe = {"date": "2026-09-01", "start_time": "19:00:00", "title": "Heels",
                "_loc_city": "SF", "chunk": None}

        def fake_parse(text, studio_id, studio_name):
            # Every chunk reports the same class, tagged with which chunk it came from.
            c = dict(dupe)
            c["chunk"] = text[:6]
            return [c]

        text = "\n\n".join("para " + "z" * 900 for _ in range(30))
        chunks = scraper._split_chunks(text)
        self.assertGreater(len(chunks), 1)
        with patch.object(scraper, "_parse_raw", fake_parse):
            result = scraper._parse_segments(chunks, "s", "S")
        # Re-run the dedup the way _parse_raw does, to assert the winner is chunk 0's.
        seen, kept = set(), []
        for group in result:
            for c in group:
                k = scraper._class_identity_key(c)
                if k not in seen:
                    seen.add(k)
                    kept.append(c)
        self.assertEqual(len(kept), 1)
        self.assertEqual(kept[0]["chunk"], chunks[0][:6])


if __name__ == "__main__":
    unittest.main()
