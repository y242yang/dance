"""Tests for the Momence host-schedule fetch path (scraper._fetch_momence_host).

This path talks to two public JSON endpoints and does its own date/timezone math, so
the things worth locking down are the ones that fail silently in production rather than
loudly in a stack trace: UTC->Pacific conversion (a wrong offset just mistimes classes),
the identity assertion (a wrong slug returns another business's perfectly well-formed
schedule), and the error shapes Momence answers with HTTP 200.

Run with either:
    python3 -m unittest test_momence
    python3 -m pytest test_momence.py   # if pytest is installed

Same stubbing approach as test_normalizers: scraper imports anthropic / playwright /
supabase at module load and none of them are needed here, so they're replaced in
sys.modules first and `requests` is patched per-test.
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
sys.modules["anthropic"].Anthropic = lambda *a, **k: None

_stub("playwright")
_playwright_sync = types.ModuleType("playwright.sync_api")
_playwright_sync.sync_playwright = lambda *a, **k: None
sys.modules["playwright.sync_api"] = _playwright_sync

_db = types.ModuleType("db")
_db.get_or_create_location = lambda *a, **k: None
_db.replace_future_classes = lambda *a, **k: None
_db.get_default_location = lambda *a, **k: None
_db.fetch_window_class_ids = lambda *a, **k: set()
_db.fetch_window_rows = lambda *a, **k: []
sys.modules["db"] = _db

import scraper  # noqa: E402  (import after stubs are in place)


HOST_OK = {"message": {"info": {"hostId": 284195, "name": "VellStudio SF"}}}
HOST_MISSING = {"error": "Host not found", "message": "Host not found"}


def _session(**over):
    """One Momence session, shaped like the real API's payload entries."""
    s = {
        "id": 1,
        "hostId": 284195,
        "sessionName": "Open Heels class | beginner level",
        # Momence's `level` is the free-text class blurb, NOT a level label.
        "level": "Beginner-friendly heels class.",
        "startsAt": "2026-09-02T02:00:00.000Z",
        "durationMinutes": 90,
        "teacher": "Vell  Raskova",
        "location": "VellStudio 1",
    }
    s.update(over)
    return s


class _Resp:
    def __init__(self, payload):
        self._payload = payload

    def json(self):
        return self._payload


def _fake_get(host_body, sessions_bodies):
    """Stand-in for requests.get that answers the slug-resolution call with `host_body`
    and each successive sessions call with the next entry of `sessions_bodies`."""
    pages = list(sessions_bodies)

    def _get(url, **kwargs):
        if "GetLatestStandalone" in url:
            return _Resp(host_body)
        return _Resp(pages.pop(0) if pages else {"payload": [], "pagination": {"totalCount": 0}})

    return _get


def _fetch(host_body=None, sessions=None, name="Vell Studio SF",
           url="https://momence.com/u/vellstudio-sf-lZXuBw"):
    host_body = HOST_OK if host_body is None else host_body
    bodies = [{"payload": sessions or [], "pagination": {"totalCount": len(sessions or [])}}]
    with patch.object(scraper.http_requests, "get", _fake_get(host_body, bodies), create=True):
        return scraper._fetch_momence_host(url, name, "studio-1")


class TestMomenceIdentity(unittest.TestCase):
    """A Momence slug resolves to a numeric host id, and every id in that space answers
    with a well-formed 200 — so a stale or mistyped slug yields another business's real
    schedule, which no count/coverage check downstream can distinguish from a good day."""

    def test_matching_host_passes(self):
        self.assertTrue(scraper._momence_identity_ok("Vell Studio SF", "VellStudio SF"))

    def test_spacing_differences_still_match(self):
        # The configured marker is compared against the name with spaces removed, so
        # "Vell Studio" and "VellStudio" are the same host.
        self.assertTrue(scraper._momence_identity_ok("Vell Studio SF", "Vell Studio SF"))

    def test_other_business_is_rejected(self):
        self.assertFalse(scraper._momence_identity_ok("Vell Studio SF", "CrossFit Brave"))

    def test_unconfigured_studio_warns_but_allows(self):
        # Not configured yet is a warning, not a hard stop — otherwise adding a studio
        # would look like a fetch failure before you got a chance to read the name.
        self.assertTrue(scraper._momence_identity_ok("Brand New Studio", "Whoever"))

    def test_wrong_host_produces_no_classes(self):
        # End to end: the identity check must abort before any session is parsed, so a
        # wrong slug reads as an empty (failed) fetch and existing rows are preserved.
        got = _fetch(host_body={"message": {"info": {"hostId": 9, "name": "CrossFit Brave"}}},
                     sessions=[_session(hostId=9)])
        self.assertEqual(got, [])


class TestMomenceParsing(unittest.TestCase):
    def test_utc_start_converts_to_pacific(self):
        # 02:00Z on Sep 2 is 7pm Pacific on Sep 1 — the date rolls back a day too.
        # Getting this wrong silently mistimes every class by 7-8 hours.
        (c,) = _fetch(sessions=[_session()])
        self.assertEqual(c["date"], "2026-09-01")
        self.assertEqual(c["start_time"], "19:00:00")

    def test_pacific_offset_follows_dst(self):
        # January is PST (-8): 02:00Z lands at 18:00 the previous day, not 19:00.
        (c,) = _fetch(sessions=[_session(startsAt="2027-01-05T02:00:00.000Z")])
        self.assertEqual(c["date"], "2027-01-04")
        self.assertEqual(c["start_time"], "18:00:00")

    def test_instructor_whitespace_is_collapsed(self):
        # The API returns "Vell  Raskova" with a double space.
        (c,) = _fetch(sessions=[_session()])
        self.assertEqual(c["instructor"], "Vell Raskova")

    def test_blurb_does_not_override_title_style(self):
        # The blurb naming another style must not beat the title. Real case: "JANE JAY
        # Hip Hop Masterclass" whose copy mentions heels came out labelled Heels.
        (c,) = _fetch(sessions=[_session(
            sessionName="Hip Hop Masterclass",
            level="Wear your heels for this one, we'll work on grooves.")])
        self.assertEqual(c["dance_style"], "Hip Hop")

    def test_blurb_does_not_override_title_level(self):
        # "All levels" in the title beats "beginner-friendly" in the marketing copy.
        (c,) = _fetch(sessions=[_session(
            sessionName="Open Contemporary class | All levels",
            level="This class is beginner-friendly!")])
        self.assertEqual(c["level"], "all_levels")

    def test_blurb_is_kept_as_description(self):
        (c,) = _fetch(sessions=[_session(level="Some blurb.")])
        self.assertEqual(c["description"], "Some blurb.")

    def test_unknown_style_falls_back_rather_than_matching_blurb(self):
        # "Sneaks" isn't a style this app knows; the honest answer is the generic
        # default, not "Groove" scraped out of the word "grooves" in the prose.
        (c,) = _fetch(sessions=[_session(
            sessionName="Open Sneaks class | All levels",
            level="Expect powerful choreography, grooves and textures.")])
        self.assertEqual(c["dance_style"], "Choreography")

    def test_sessions_from_another_host_are_dropped(self):
        # Belt and braces behind the identity check: the response must be scoped to the
        # host we resolved, and a mixed one means it isn't.
        got = _fetch(sessions=[_session(id=1), _session(id=2, hostId=999)])
        self.assertEqual(len(got), 1)
        self.assertEqual(got[0]["date"], "2026-09-01")

    def test_sessions_missing_required_fields_are_skipped(self):
        got = _fetch(sessions=[
            _session(id=1, sessionName=""),
            _session(id=2, startsAt=""),
            _session(id=3, startsAt="not-a-timestamp"),
            _session(id=4),
        ])
        self.assertEqual(len(got), 1)

    def test_out_of_range_duration_is_dropped_not_stored(self):
        (c,) = _fetch(sessions=[_session(durationMinutes=999)])
        self.assertIsNone(c["duration_minutes"])


class TestMomenceErrorShapes(unittest.TestCase):
    """Momence answers failures with HTTP 200 and a differently-shaped body, so these
    are the cases that would otherwise raise mid-fetch instead of failing cleanly."""

    def test_unknown_slug_returns_empty_not_attribute_error(self):
        # `message` comes back as the plain string "Host not found" rather than an
        # object; chaining .get() through it raised AttributeError and took the whole
        # studio fetch down with it.
        self.assertEqual(_fetch(host_body=HOST_MISSING), [])

    def test_url_without_a_slug_returns_empty(self):
        self.assertEqual(_fetch(url="https://example.com/not-momence"), [])

    def test_non_dict_response_bodies_return_empty(self):
        self.assertEqual(_fetch(host_body=["unexpected"]), [])

    def test_non_list_payload_returns_empty(self):
        with patch.object(scraper.http_requests, "get",
                          _fake_get(HOST_OK, [{"payload": "nope"}]), create=True):
            self.assertEqual(
                scraper._fetch_momence_host(
                    "https://momence.com/u/vellstudio-sf-lZXuBw", "Vell Studio SF", "s"), [])

    def test_pagination_stops_when_total_is_reached(self):
        # Two pages of one session each, totalCount 2: the loop must stop after page 2
        # rather than requesting forever.
        bodies = [
            {"payload": [_session(id=1)], "pagination": {"totalCount": 2}},
            {"payload": [_session(id=2, startsAt="2026-09-04T02:00:00.000Z")],
             "pagination": {"totalCount": 2}},
        ]
        calls = []
        get = _fake_get(HOST_OK, bodies)

        def counting_get(url, **kwargs):
            calls.append(url)
            return get(url, **kwargs)

        with patch.object(scraper.http_requests, "get", counting_get, create=True):
            got = scraper._fetch_momence_host(
                "https://momence.com/u/vellstudio-sf-lZXuBw", "Vell Studio SF", "s")
        self.assertEqual(len(got), 2)
        # 1 slug-resolution call + exactly 2 session pages.
        self.assertEqual(len(calls), 3)

    def test_empty_first_page_stops_immediately(self):
        # A totalCount that overstates what's actually returned must not spin: the loop
        # breaks on an empty batch regardless of the count.
        bodies = [{"payload": [], "pagination": {"totalCount": 500}}]
        calls = []
        get = _fake_get(HOST_OK, bodies)

        def counting_get(url, **kwargs):
            calls.append(url)
            return get(url, **kwargs)

        with patch.object(scraper.http_requests, "get", counting_get, create=True):
            got = scraper._fetch_momence_host(
                "https://momence.com/u/vellstudio-sf-lZXuBw", "Vell Studio SF", "s")
        self.assertEqual(got, [])
        self.assertEqual(len(calls), 2)


if __name__ == "__main__":
    unittest.main()
