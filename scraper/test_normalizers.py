"""Unit tests for the pure normalization helpers in scraper.py.

These functions encode tricky precedence rules (combo-levels before single levels,
"Heels" winning over themed styles, stable class ids) that are easy to break silently,
so they're worth locking down.

Run with either:
    python3 -m unittest test_normalizers
    python3 -m pytest test_normalizers.py   # if pytest is installed

The scraper module pulls in anthropic / playwright / supabase at import time, none of
which the normalizers actually need. We stub those modules in sys.modules first so this
test runs with only the standard library installed.
"""
import sys
import types
import unittest


def _stub(name):
    if name not in sys.modules:
        sys.modules[name] = types.ModuleType(name)


# --- stub heavy third-party imports before importing scraper -----------------
_stub("requests")

_stub("anthropic")
sys.modules["anthropic"].Anthropic = lambda *a, **k: None  # never called in these tests

_stub("playwright")
_playwright_sync = types.ModuleType("playwright.sync_api")
_playwright_sync.sync_playwright = lambda *a, **k: None
sys.modules["playwright.sync_api"] = _playwright_sync

# scraper does `from db import ...`; provide a stand-in module.
_db = types.ModuleType("db")
_db.get_or_create_location = lambda *a, **k: None
_db.replace_future_classes = lambda *a, **k: None
_db.get_default_location = lambda *a, **k: None
sys.modules["db"] = _db

import scraper  # noqa: E402  (import after stubs are in place)


class TestNormalizeLevel(unittest.TestCase):
    def test_maps_open_to_all_levels(self):
        self.assertEqual(scraper._normalize_level("open"), "all_levels")
        self.assertEqual(scraper._normalize_level("All Levels"), "all_levels")

    def test_empty_defaults_to_all_levels(self):
        self.assertEqual(scraper._normalize_level(None), "all_levels")
        self.assertEqual(scraper._normalize_level(""), "all_levels")

    def test_passthrough_valid_level(self):
        self.assertEqual(scraper._normalize_level("beginner"), "beginner")
        self.assertEqual(scraper._normalize_level("advanced"), "advanced")

    def test_combo_levels_win_over_single(self):
        # "int/adv" must be detected before the bare "adv" / "inter" branches.
        self.assertEqual(scraper._normalize_level("Intermediate/Advanced"), "int/adv")
        self.assertEqual(scraper._normalize_level("Beg/Int"), "begin/int")

    def test_clues_from_title_when_raw_generic(self):
        # raw says all_levels, but the title reveals something more specific.
        self.assertEqual(
            scraper._normalize_level("open", title="Advanced Heels"), "advanced"
        )
        self.assertEqual(
            scraper._normalize_level(None, title="Beginner Hip Hop"), "beginner"
        )

    def test_master(self):
        self.assertEqual(scraper._normalize_level(None, title="Master Class"), "master")


class TestNormalizeStyle(unittest.TestCase):
    def test_heels_wins_over_theme(self):
        # A themed heels class is still "Heels" regardless of raw value.
        self.assertEqual(
            scraper._normalize_style("Reggaeton", title="Reggaeton Heels"), "Heels"
        )
        self.assertEqual(scraper._normalize_style(None, title="Chair Heels"), "Heels")

    def test_style_map_aliases(self):
        self.assertEqual(scraper._normalize_style("hip-hop"), "Hip Hop")
        self.assertEqual(scraper._normalize_style("kpop"), "K-pop")
        self.assertEqual(scraper._normalize_style("jazzfunk"), "Jazz Funk")

    def test_passthrough_valid_style(self):
        self.assertEqual(scraper._normalize_style("Ballet"), "Ballet")

    def test_fallback_to_choreography(self):
        self.assertEqual(scraper._normalize_style("something weird"), "Choreography")
        self.assertEqual(scraper._normalize_style(None), "Choreography")

    def test_clue_from_title_when_raw_generic(self):
        # raw is the generic fallback, but the title names a real style.
        self.assertEqual(
            scraper._normalize_style("Choreography", title="Salsa Night"), "Salsa"
        )

    def test_reggaeton_and_dancehall_not_conflated(self):
        self.assertEqual(scraper._normalize_style("reggaeton"), "Reggaeton")
        self.assertEqual(scraper._normalize_style("dancehall"), "Dancehall")


class TestNormalizeDuration(unittest.TestCase):
    def test_valid_range(self):
        self.assertEqual(scraper._normalize_duration(60), 60)
        self.assertEqual(scraper._normalize_duration("90"), 90)

    def test_out_of_range_is_none(self):
        self.assertIsNone(scraper._normalize_duration(5))     # too short
        self.assertIsNone(scraper._normalize_duration(500))   # too long

    def test_non_numeric_is_none(self):
        self.assertIsNone(scraper._normalize_duration(None))
        self.assertIsNone(scraper._normalize_duration("abc"))


class TestStableClassId(unittest.TestCase):
    def test_deterministic(self):
        c = {"title": "Heels 101", "date": "2026-07-10", "start_time": "19:00:00"}
        first = scraper._stable_class_id("studio-a", c)
        second = scraper._stable_class_id("studio-a", c)
        self.assertEqual(first, second)

    def test_title_case_and_whitespace_insensitive(self):
        a = scraper._stable_class_id(
            "s", {"title": "Heels 101", "date": "2026-07-10", "start_time": "19:00:00"}
        )
        b = scraper._stable_class_id(
            "s", {"title": "  heels 101 ", "date": "2026-07-10", "start_time": "19:00:00"}
        )
        self.assertEqual(a, b)

    def test_different_inputs_differ(self):
        base = {"title": "Heels 101", "date": "2026-07-10", "start_time": "19:00:00"}
        other_time = dict(base, start_time="20:00:00")
        self.assertNotEqual(
            scraper._stable_class_id("s", base),
            scraper._stable_class_id("s", other_time),
        )
        self.assertNotEqual(
            scraper._stable_class_id("studio-a", base),
            scraper._stable_class_id("studio-b", base),
        )


class TestMaxClassDate(unittest.TestCase):
    def test_none_when_empty(self):
        self.assertIsNone(scraper._max_class_date([]))

    def test_none_when_no_dates(self):
        self.assertIsNone(scraper._max_class_date([{"title": "x"}, {"date": None}]))

    def test_returns_latest_date(self):
        classes = [
            {"date": "2026-07-10"},
            {"date": "2026-07-22"},
            {"date": "2026-07-15"},
        ]
        self.assertEqual(scraper._max_class_date(classes), "2026-07-22")

    def test_ignores_missing_dates_among_present(self):
        classes = [{"date": "2026-07-10"}, {"title": "no date"}]
        self.assertEqual(scraper._max_class_date(classes), "2026-07-10")


if __name__ == "__main__":
    unittest.main()
