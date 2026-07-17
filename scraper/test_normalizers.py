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
from unittest.mock import patch


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

    def test_groove_from_title(self):
        self.assertEqual(scraper._normalize_style(None, title="BEG/INT Grooves (Ages 13+)"), "Groove")
        self.assertEqual(scraper._normalize_style(None, title="Groove Session"), "Groove")
        # word boundary: "groovy" is not "groove"
        self.assertEqual(scraper._normalize_style(None, title="Groovy Vibes"), "Choreography")

    def test_groove_from_title_only_when_raw_unresolved(self):
        # raw is checked first: a raw value that itself matches nothing (the
        # "Choreography" fallback, or empty) falls through to the title, where an
        # explicit "Grooves" is picked up.
        self.assertEqual(scraper._normalize_style("Choreography", title="BEG/INT Grooves (Ages 13+)"), "Groove")
        self.assertEqual(scraper._normalize_style(None, title="INT/ADV Grooves (Ages 13+)"), "Groove")

    def test_raw_wins_over_title_groove_when_raw_is_a_real_style(self):
        # raw takes priority over any title/description clue, including "grooves",
        # when raw itself already matches a real style -- raw is informed by the
        # full page context, so it's trusted over a bare title keyword. (This is why
        # "Groove" was added as a real choice in the Haiku PROMPT: the fix for an
        # inconsistent raw guess belongs at the source, not in a title override that
        # would also demote a *correct* raw classification for every other style.)
        self.assertEqual(scraper._normalize_style("Jazz Funk", title="INT/ADV Grooves (Ages 13+)"), "Jazz Funk")
        self.assertEqual(scraper._normalize_style("House", title="House & Hip-Hop Grooves"), "House")
        self.assertEqual(scraper._normalize_style("Hip Hop", title="Foundations: Grooves"), "Hip Hop")

    def test_title_groove_still_applies_when_raw_generic(self):
        # A class that's more specifically Hip Hop/House and also says "grooves"
        # keeps the more specific label when title is consulted -- Groove is the
        # last resort within the pattern list, not an override.
        self.assertEqual(scraper._normalize_style(None, title="House & Hip-Hop Grooves"), "Hip Hop")
        self.assertEqual(scraper._normalize_style(None, title="All Levels House Grooves"), "House")
        self.assertEqual(scraper._normalize_style(None, title="Foundations: Grooves"), "Groove")


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

    def test_different_locations_get_different_ids(self):
        # Regression guard: _parse_raw_by_day's dedup (_add_deduped) deliberately
        # keeps two locations' identically-timed/titled classes as distinct rows
        # (see TestParseRawByDay.test_different_locations_are_not_deduped_together).
        # If _stable_class_id ignored location, both would hash to the same DB id
        # and the upsert would crash with "ON CONFLICT DO UPDATE command cannot
        # affect row a second time" for a real multi-location collision, not just
        # the stale-tiles-race duplicate this feature was built to fix.
        base = {"title": "Open Level Hip Hop", "date": "2026-07-13", "start_time": "18:00:00"}
        fremont = scraper._stable_class_id("s", dict(base, _loc_city="Fremont"))
        cupertino = scraper._stable_class_id("s", dict(base, _loc_city="Cupertino"))
        self.assertNotEqual(fremont, cupertino)

    def test_no_location_matches_id_without_location_field(self):
        # Backward compatibility: a class dict with no _loc_city at all (the vast
        # majority -- single-location studios never populate this field) must hash
        # to the exact same id it always has, so existing "saved"/hearted class
        # references aren't invalidated by adding location to the identity key.
        base = {"title": "Heels 101", "date": "2026-07-10", "start_time": "19:00:00"}
        without_field = scraper._stable_class_id("s", base)
        with_none = scraper._stable_class_id("s", dict(base, _loc_city=None))
        with_empty = scraper._stable_class_id("s", dict(base, _loc_city=""))
        self.assertEqual(without_field, with_none)
        self.assertEqual(without_field, with_empty)

    def test_location_case_and_whitespace_insensitive(self):
        base = {"title": "Heels 101", "date": "2026-07-10", "start_time": "19:00:00"}
        a = scraper._stable_class_id("s", dict(base, _loc_city="San Jose"))
        b = scraper._stable_class_id("s", dict(base, _loc_city="  san jose "))
        self.assertEqual(a, b)


class TestInjectLocationHint(unittest.TestCase):
    """Regression coverage for a real bug: the location hint used to be prepended
    as a plain prefix before a url's whole marker-tagged text, which _parse_raw_by_day
    then sliced into the TAIL of the PRECEDING location's last-day segment instead of
    into this location's own days (segments run from one marker's end to the next
    marker's start). _inject_location_hint fixes this by inserting the hint right
    after each marker instead of before the whole block."""

    def test_hint_lands_in_first_days_own_segment_not_before_it(self):
        t = "===CLASSDATE:2026-07-13===\nseg one\n===CLASSDATE:2026-07-14===\nseg two"
        tagged = scraper._inject_location_hint(t, "Fremont")
        markers = list(scraper._DAY_TAG_RE.finditer(tagged))
        self.assertEqual(len(markers), 2)
        first_segment = tagged[markers[0].end():markers[1].start()]
        self.assertIn("[Location: Fremont, CA]", first_segment)
        self.assertIn("seg one", first_segment)

    def test_multi_location_concatenation_keeps_hints_with_their_own_city(self):
        # Simulates _fetch_studio concatenating two locations' texts together --
        # each location's own day segment must carry its own hint, and only its own.
        t1 = scraper._inject_location_hint("===CLASSDATE:2026-07-13===\nFremont day", "Fremont")
        t2 = scraper._inject_location_hint("===CLASSDATE:2026-07-13===\nCupertino day", "Cupertino")
        all_text = "\n\n" + t1 + "\n\n" + t2
        markers = list(scraper._DAY_TAG_RE.finditer(all_text))
        self.assertEqual(len(markers), 2)
        seg0 = all_text[markers[0].end():markers[1].start()]
        seg1 = all_text[markers[1].end():]
        self.assertIn("[Location: Fremont, CA]", seg0)
        self.assertNotIn("Cupertino", seg0)
        self.assertIn("[Location: Cupertino, CA]", seg1)
        self.assertNotIn("Fremont", seg1)

    def test_no_markers_falls_back_to_prefix(self):
        t = "no markers here, just plain schedule text"
        tagged = scraper._inject_location_hint(t, "Fremont")
        self.assertEqual(tagged, "[Location: Fremont, CA]\nno markers here, just plain schedule text")


class TestParseRawByDay(unittest.TestCase):
    """_parse_raw_by_day and its _add_deduped dedup have caused two real production
    bugs this session (a dropped day, and an ON CONFLICT DO UPDATE crash from a
    duplicate day-capture) and previously shipped with zero test coverage. _parse_raw
    itself makes a real Claude Haiku API call, so these mock it out and test the
    marker-splitting / date-forcing / dedup logic in isolation."""

    def test_splits_by_marker_and_forces_date_ignoring_parsed_date(self):
        page_text = (
            "===CLASSDATE:2026-07-13===\nseg one\n"
            "===CLASSDATE:2026-07-14===\nseg two"
        )
        # Haiku's own "date" field (here deliberately wrong) must be overridden by
        # the marker's date, not trusted.
        with patch.object(scraper, "_parse_raw", side_effect=[
            [{"date": "1999-01-01", "start_time": "18:00:00", "title": "Class A"}],
            [{"date": "1999-01-01", "start_time": "19:00:00", "title": "Class B"}],
        ]):
            result = scraper._parse_raw_by_day(page_text, "studio-1", "Test Studio")
        self.assertEqual(sorted(c["date"] for c in result), ["2026-07-13", "2026-07-14"])
        self.assertEqual({c["title"] for c in result}, {"Class A", "Class B"})

    def test_dedups_a_repeated_day_capture(self):
        # Same marker date appearing twice simulates the stale-tiles race
        # re-capturing the same calendar week -- both segments parse to the
        # identical class.
        page_text = (
            "===CLASSDATE:2026-07-13===\nseg one\n"
            "===CLASSDATE:2026-07-13===\nseg one again"
        )
        same_class = {"date": "1999-01-01", "start_time": "18:00:00", "title": "Class A"}
        with patch.object(scraper, "_parse_raw", side_effect=[[dict(same_class)], [dict(same_class)]]):
            result = scraper._parse_raw_by_day(page_text, "studio-1", "Test Studio")
        self.assertEqual(len(result), 1)

    def test_dedup_is_case_and_whitespace_insensitive_like_stable_class_id(self):
        # Regression guard: the dedup key must match _stable_class_id's own
        # normalization (via the shared _class_identity_key), or a title differing
        # only by case/whitespace could pass dedup as "different" and then collide
        # once _stable_class_id normalizes it for the DB upsert.
        page_text = (
            "===CLASSDATE:2026-07-13===\nseg one\n"
            "===CLASSDATE:2026-07-13===\nseg one again"
        )
        with patch.object(scraper, "_parse_raw", side_effect=[
            [{"date": "x", "start_time": "18:00:00", "title": "Class A"}],
            [{"date": "x", "start_time": "18:00:00", "title": "  class a  "}],
        ]):
            result = scraper._parse_raw_by_day(page_text, "studio-1", "Test Studio")
        self.assertEqual(len(result), 1)

    def test_different_locations_are_not_deduped_together(self):
        # Same date/time/title at two different locations of a multi-location
        # studio are genuinely different classes -- must not collapse into one.
        page_text = (
            "===CLASSDATE:2026-07-13===\nseg one\n"
            "===CLASSDATE:2026-07-13===\nseg two"
        )
        with patch.object(scraper, "_parse_raw", side_effect=[
            [{"date": "x", "start_time": "18:00:00", "title": "Class A", "_loc_city": "Fremont"}],
            [{"date": "x", "start_time": "18:00:00", "title": "Class A", "_loc_city": "Cupertino"}],
        ]):
            result = scraper._parse_raw_by_day(page_text, "studio-1", "Test Studio")
        self.assertEqual(len(result), 2)

    def test_no_markers_falls_back_to_plain_parse_raw(self):
        page_text = "no markers in this text at all"
        with patch.object(scraper, "_parse_raw", return_value=[{"title": "Class A"}]) as mock_parse:
            result = scraper._parse_raw_by_day(page_text, "studio-1", "Test Studio")
        mock_parse.assert_called_once_with(page_text, "studio-1", "Test Studio")
        self.assertEqual(result, [{"title": "Class A"}])


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
