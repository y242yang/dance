"""Tests for main.exit_code — the daily run's only unattended failure signal.

main.py imports db (supabase, dotenv) and scraper (anthropic, playwright) at module
load; all four are stubbed here so this runs with only the standard library.
"""
import sys
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
_stub("supabase")
sys.modules["supabase"].create_client = lambda *a, **k: None
sys.modules["supabase"].Client = object
_stub("dotenv")
sys.modules["dotenv"].load_dotenv = lambda *a, **k: None

# test_normalizers stubs a fake `db`; either that or the real one works here, since
# these tests never touch the DB. Only main.exit_code and main.run are exercised.
if "db" not in sys.modules:
    _db = types.ModuleType("db")
    _db.get_studios = lambda: []
    _db.delete_past_classes = lambda: None
    _db.delete_past_log_entries = lambda: None
    _db.get_or_create_location = lambda *a, **k: None
    _db.replace_future_classes = lambda *a, **k: None
    _db.get_default_location = lambda *a, **k: None
    _db.fetch_window_class_ids = lambda *a, **k: set()
    _db.fetch_window_rows = lambda *a, **k: []
    sys.modules["db"] = _db
else:
    for _name, _fn in (("get_studios", lambda: []),
                       ("delete_past_classes", lambda: None),
                       ("delete_past_log_entries", lambda: None)):
        if not hasattr(sys.modules["db"], _name):
            setattr(sys.modules["db"], _name, _fn)

import main  # noqa: E402


def _summary(complete=(), partial=(), failed=(), unverified=(), total=None):
    names = list(complete) + list(partial) + list(failed) + list(unverified)
    return {"complete": list(complete), "partial": list(partial),
            "failed": list(failed), "unverified": list(unverified),
            "total": len(names) if total is None else total}


class TestExitCode(unittest.TestCase):
    def test_all_complete_succeeds(self):
        self.assertEqual(main.exit_code(_summary(complete=["A", "B"])), 0)

    def test_any_failed_studio_fails_the_run(self):
        # The Enjoy Dance Studio case: one studio kept stale data while the rest wrote.
        self.assertEqual(
            main.exit_code(_summary(complete=["A", "B"], failed=["Enjoy Dance Studio"])), 1)

    def test_partial_alone_does_not_fail_the_run(self):
        # Full Out / VIBE are partial most days by nature of their booking widgets;
        # failing on partial would make the signal permanently red and meaningless.
        self.assertEqual(
            main.exit_code(_summary(complete=["A"], partial=["Full Out Studios",
                                                             "VIBE AT THE WALL"])), 0)

    def test_partial_and_failed_together_still_fails(self):
        self.assertEqual(
            main.exit_code(_summary(partial=["A"], failed=["B"])), 1)

    def test_unverified_write_fails_the_run(self):
        # Rows were written but read back as something else — nobody can tell which rows
        # the app is showing, so this needs a human, not a log line.
        self.assertEqual(
            main.exit_code(_summary(complete=["A"], unverified=["B"])), 1)

    def test_summary_without_unverified_key_still_succeeds(self):
        # Back-compat: a summary predating the unverified bucket must not read as failure.
        self.assertEqual(
            main.exit_code({"complete": ["A"], "partial": [], "failed": [], "total": 1}), 0)

    def test_zero_studios_fails(self):
        # An empty studio list is a broken query/config, not an absence of work.
        self.assertEqual(main.exit_code(_summary(total=0)), 1)

    def test_missing_keys_are_treated_as_no_work(self):
        # Defensive: a summary shape change shouldn't silently return success.
        self.assertEqual(main.exit_code({}), 1)


class TestRunReturnsSummary(unittest.TestCase):
    def test_run_passes_scrape_all_summary_through(self):
        # Guards the wiring: run() must return what scrape_all reported, or the exit
        # code is computed from nothing and every run goes green again.
        summary = _summary(complete=["A"], failed=["B"])
        with patch.object(main, "delete_past_classes", lambda: None), \
             patch.object(main, "delete_past_log_entries", lambda: None), \
             patch.object(main, "get_studios", lambda: [{"id": "1", "name": "A"},
                                                        {"id": "2", "name": "B"}]), \
             patch.object(main, "scrape_all", lambda studios: summary):
            self.assertEqual(main.run(), summary)


if __name__ == "__main__":
    unittest.main()
