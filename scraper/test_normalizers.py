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

    def test_no_substring_false_positives(self):
        # Whole-word matching: these words CONTAIN level fragments but aren't levels.
        self.assertEqual(scraper._normalize_level(None, title="Advanced Pointe"), "advanced")  # not int/adv
        self.assertEqual(scraper._normalize_level(None, title="Winter Showcase"), "all_levels")  # winter⊃int
        self.assertEqual(scraper._normalize_level(None, title="Art Jam", description="painting themed"), "all_levels")
        self.assertEqual(scraper._normalize_level("all_levels", title="Flow", description="we advise knee pads"), "all_levels")

    def test_combo_order_independent(self):
        self.assertEqual(scraper._normalize_level("Adv/Int"), "int/adv")
        self.assertEqual(scraper._normalize_level("Int/Adv"), "int/adv")

    def test_beginner_to_advanced_is_all_levels(self):
        self.assertEqual(scraper._normalize_level(None, title="Beginner to Advanced"), "all_levels")

    def test_all_levels_yields_to_a_specific_level(self):
        # The full level-selection rule set:
        # 1. "all levels"/"open" alone            -> all_levels
        self.assertEqual(scraper._normalize_level("all levels"), "all_levels")
        self.assertEqual(scraper._normalize_level(None, title="Open Level"), "all_levels")
        # 2. "all levels" + a specific level      -> the specific level wins
        self.assertEqual(scraper._normalize_level(None, title="All Levels — Advanced Technique"), "advanced")
        self.assertEqual(scraper._normalize_level(None, title="Open Level, Beginner Friendly"), "beginner")
        self.assertEqual(scraper._normalize_level(None, title="All Levels Int/Adv"), "int/adv")
        # 3. no level signal at all               -> all_levels (fallback)
        self.assertEqual(scraper._normalize_level(None, title="Summer Groove Session"), "all_levels")
        # +. only a specific level (no "all")     -> that level
        self.assertEqual(scraper._normalize_level(None, title="Advanced Heels"), "advanced")


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

    def test_popping_afro_twerk_passthrough(self):
        self.assertEqual(scraper._normalize_style("Popping"), "Popping")
        self.assertEqual(scraper._normalize_style("popping"), "Popping")
        self.assertEqual(scraper._normalize_style("Afro"), "Afro")
        self.assertEqual(scraper._normalize_style("Twerk"), "Twerk")

    def test_popping_afro_twerk_from_title(self):
        self.assertEqual(scraper._normalize_style(None, title="Popping Fundamentals"), "Popping")
        self.assertEqual(scraper._normalize_style(None, title="Poppin' Session"), "Popping")
        self.assertEqual(scraper._normalize_style(None, title="Afrobeats with Sri"), "Afro")
        self.assertEqual(scraper._normalize_style(None, title="Twerk Technique"), "Twerk")

    def test_heels_still_wins_over_twerk(self):
        # The Heels override must beat a themed style like Twerk.
        self.assertEqual(scraper._normalize_style("Twerk", title="Twerk Heels"), "Heels")

    def test_style_no_substring_false_positives(self):
        # Whole-word matching: these contain style fragments but aren't those styles.
        self.assertEqual(scraper._normalize_style(None, title="Warehouse Party"), "Choreography")  # warehouse⊃house
        self.assertEqual(scraper._normalize_style(None, title="Open Flow", description="wheelchair accessible"), "Choreography")  # wheelchair⊃chair

    def test_specific_phrase_beats_generic(self):
        # More-specific patterns must win over their generic substring.
        self.assertEqual(scraper._normalize_style(None, title="Jazz Funk Fundamentals"), "Jazz Funk")  # not Jazz
        self.assertEqual(scraper._normalize_style(None, title="Chinese Fusion"), "Chinese Fusion")  # not Chinese
        self.assertEqual(scraper._normalize_style(None, title="Bachata Latin Night"), "Bachata")  # not Latin

    def test_krump_waacking_bachata(self):
        for raw in ("Krump", "krump"):
            self.assertEqual(scraper._normalize_style(raw), "Krump")
        self.assertEqual(scraper._normalize_style("Waacking"), "Waacking")
        self.assertEqual(scraper._normalize_style("Bachata"), "Bachata")
        self.assertEqual(scraper._normalize_style(None, title="Krumping Session"), "Krump")
        self.assertEqual(scraper._normalize_style(None, title="Waacking Fundamentals"), "Waacking")


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
