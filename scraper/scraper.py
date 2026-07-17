import json
import os
import re
import uuid
import multiprocessing as mp
import requests as http_requests
import anthropic
from datetime import date, timedelta
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from playwright.sync_api import sync_playwright
from db import get_or_create_location, replace_future_classes, get_default_location

# Fixed namespace so the same (studio, title, date, start_time) always hashes to the
# same class id across scrapes — lets clients (e.g. "saved"/hearted classes) reference
# a class by id without it being invalidated by the next day's re-scrape.
_CLASS_ID_NAMESPACE = uuid.UUID("7d6f5b0a-6b7e-4b8a-9b0a-6b7e4b8a9b0a")

def _class_identity_key(c: dict) -> tuple:
    """Canonical (date, start_time, normalized title, normalized location) identity
    for a class dict -- single source of truth for "is this the same class", shared
    by _stable_class_id (the DB's actual uniqueness key) and every in-memory dedup
    pass over parsed classes. Previously each dedup pass hand-rolled its own slightly
    different normalization (one truncated title to 30 chars without lowering it,
    another lowered/stripped the full title, another bolted a raw un-normalized
    location onto the end) -- close enough to usually agree, but a title differing
    only by case or only past character 30, or a location differing only by case,
    could pass one of those checks as "different" and then collide once
    _stable_class_id normalized its own key, reproducing an ON CONFLICT DO UPDATE
    upsert crash through a path no dedup was actually guarding. Routing every one of
    these through this single function means they can't drift out of sync with each
    other or with what actually determines an upsert collision."""
    return (
        c.get("date"),
        c.get("start_time"),
        (c.get("title") or "").strip().lower(),
        (c.get("_loc_city") or "").strip().lower(),
    )


def _stable_class_id(studio_id: str, c: dict) -> str:
    cls_date, start_time, title, loc_city = _class_identity_key(c)
    key = f"{studio_id}|{title}|{cls_date}|{start_time}"
    # Only fold location into the id when one was actually resolved, so studios that
    # never populate _loc_city (the vast majority -- single-location studios) keep
    # hashing to the exact same id they always have, and existing "saved"/hearted
    # class references for them aren't invalidated by this change. Multi-location
    # studios where two branches genuinely offer the same title at the same time
    # need it, or both classes hash to one id and the upsert crashes with "ON
    # CONFLICT DO UPDATE command cannot affect row a second time" -- the identity
    # key must fold in every input _add_deduped uses to tell two classes apart, since
    # it is meant to be the same "is this the same class" answer as the in-memory dedup.
    if loc_city:
        key += f"|{loc_city}"
    return str(uuid.uuid5(_CLASS_ID_NAMESPACE, key))

_default_location_cache = {}  # studio_id -> Optional[str]

# Upper bound on pagination clicks/pages for the "click through weeks" scrapers. This is
# only a runaway guard — the real stop condition is reaching the days-ahead cutoff date
# (or running out of Next buttons). Set high enough that 14 days is never truncated.
_PAGINATION_MAX_CLICKS = 25

# Mindbody day-tile widgets use div[role="button"] for both actual day tiles and the
# Previous/Next/Open-calendar controls; this excludes the latter by aria-label. Shared
# by every place in fetch_page_text that collects or fingerprints day tiles so they
# can't drift out of sync with each other.
_NAV_LABELS = {"next", "previous", "open calendar"}

# Created lazily on first use so the module can be imported (e.g. by unit tests that
# only exercise the pure normalizer functions) without an ANTHROPIC_API_KEY set.
_anthropic = None

def _get_anthropic():
    global _anthropic
    if _anthropic is None:
        _anthropic = anthropic.Anthropic()
    return _anthropic

_VALID_LEVELS = {"beginner", "intermediate", "advanced", "begin/int", "int/adv", "all_levels", "master"}

# Whole-word synonyms → canonical level token. Matched against WORDS in the text (via
# re.findall below), never substrings, so "pointe"/"winter"/"advise" can't spuriously
# trigger int/adv/etc. A slash form like "Int/Adv" tokenizes to {int, adv} → int/adv.
_LEVEL_WORDS = {
    "beginner": "beg", "beginners": "beg", "beg": "beg", "beginning": "beg",
    "intermediate": "int", "intermediates": "int", "inter": "int", "int": "int",
    "advanced": "adv", "adv": "adv",
    "master": "master", "masters": "master", "masterclass": "master",
}

_VALID_STYLES = {
    "Hip Hop", "Heels", "Jazz Funk", "K-pop", "Contemporary", "Ballet",
    "Salsa", "Reggaeton", "Dancehall", "Breaking", "House", "Vogue", "Turfing",
    "Jazz", "Chinese", "Chinese Fusion", "Pro Dance", "Choreography",
    "Locking", "Latin", "Popping", "Afro", "Twerk", "Krump", "Waacking", "Bachata",
    "Groove",
}

# Ordered (priority) patterns → canonical style; first match wins. Each is matched with
# word boundaries (\b...\b) so "warehouse" can't match "house" and "wheelchair" can't
# match "chair". More-specific phrases precede their generic parts (jazz funk before
# jazz, chinese fusion before chinese). [\s-]? allows "hip hop"/"hip-hop"/"hiphop" etc.
# Keep the set of labels here in sync with _VALID_STYLES, the Haiku PROMPT, and the iOS
# styleColor map.
_STYLE_PATTERNS = [
    (r"hip[\s-]?hop", "Hip Hop"),
    (r"jazz[\s-]?funk", "Jazz Funk"),
    (r"k[\s-]?pop", "K-pop"),
    (r"heels", "Heels"),
    (r"reggaeton", "Reggaeton"),
    (r"dancehall", "Dancehall"),
    (r"salsa", "Salsa"),
    (r"ballet", "Ballet"),
    (r"contemporary", "Contemporary"),
    (r"breaking", "Breaking"),
    (r"house", "House"),
    (r"vogue", "Vogue"),
    (r"turfing", "Turfing"),
    (r"floorwork", "Heels"),
    (r"chair", "Heels"),
    (r"chinese\s+fusion", "Chinese Fusion"),
    (r"chinese", "Chinese"),
    (r"pro[\s-]?dance", "Pro Dance"),
    (r"popping|poppin", "Popping"),
    (r"twerk", "Twerk"),
    (r"afrobeats?|afro", "Afro"),
    (r"locking", "Locking"),
    (r"krumping|krump", "Krump"),
    (r"waacking|waack", "Waacking"),
    (r"bachata", "Bachata"),  # before "latin": Bachata is a Latin genre but its own style
    (r"latin", "Latin"),
    (r"jazz", "Jazz"),
    # Last resort before the generic "Choreography" default -- a "Groove(s)"-titled
    # class with no other, more specific style keyword lands here rather than
    # Choreography. Deliberately last: a class that's more specifically Hip Hop,
    # House, Jazz Funk, etc. and also happens to say "grooves" should keep that more
    # specific label, not get bucketed into Groove.
    (r"grooves?", "Groove"),
]

def _normalize_level(raw, title: str = "", description: str = "") -> str:
    combined = " ".join(filter(None, [str(raw or ""), title, description])).lower()
    words = set(re.findall(r"[a-z]+", combined))
    toks = {_LEVEL_WORDS[w] for w in words if w in _LEVEL_WORDS}
    beg, inter, adv, master = ("beg" in toks, "int" in toks, "adv" in toks, "master" in toks)
    if inter and adv:
        return "int/adv"
    if beg and inter:
        return "begin/int"
    if master:
        return "master"
    if beg and adv:
        return "all_levels"  # spans the whole range → treat as all levels
    if adv:
        return "advanced"
    if beg:
        return "beginner"
    if inter:
        return "intermediate"
    return "all_levels"

def _max_class_date(classes: list) -> "str | None":
    """The latest YYYY-MM-DD date among parsed classes, or None if there are none.
    Used as the 'covered_through' watermark: we only trust (and prune) rows up to the
    furthest date we actually scraped."""
    dates = [c.get("date") for c in classes if c.get("date")]
    return max(dates) if dates else None


def _normalize_duration(raw) -> "int | None":
    if raw is None:
        return None
    try:
        mins = int(raw)
        return mins if 15 <= mins <= 240 else None
    except (ValueError, TypeError):
        return None

def _match_style(text: str) -> "str | None":
    """First style whose whole-word/phrase pattern appears in `text`, else None.
    Word boundaries prevent substring false-positives (warehouse≠house, wheelchair≠chair)."""
    if not text:
        return None
    t = text.lower()
    for pattern, label in _STYLE_PATTERNS:
        if re.search(r"\b(?:" + pattern + r")\b", t):
            return label
    return None

def _normalize_style(raw, title: str = "", description: str = "") -> str:
    combined = " ".join(filter(None, [title, description]))
    # 1. Classify normally: trust Haiku's own dance_style label first -- raw is
    #    informed by the full page context (not just this class's own title/
    #    description), so it's usually the more reliable signal -- falling back to
    #    clues in the title/description only when raw didn't match a real style,
    #    then the generic "Choreography" default.
    #    An earlier version of this function checked title/description BEFORE raw,
    #    specifically to make "Grooves"-titled classes land on "Groove" reliably
    #    instead of whatever genre Haiku had to force-guess before "Groove" was a
    #    real option. That was reverted: checking title first is a global change
    #    that lets ANY incidental keyword in the title/description outrank a
    #    correct, more-informed raw classification, for every style, not just
    #    Groove -- e.g. a class raw="Waacking" (correct) whose description happens
    #    to mention "hip hop" would get relabeled "Hip Hop", since patterns are
    #    matched by list position, not by relevance to the actual class. The right
    #    fix for Groove specifically is at the source: "Groove" is now one of
    #    Haiku's own choices (see PROMPT below), so raw should increasingly say
    #    "Groove" directly for these classes without needing title to override raw
    #    at all. Patterns within _match_style are still ordered by specificity
    #    (Hip Hop, Jazz Funk, House, etc. all precede the catch-all "grooves?"
    #    pattern), so when raw doesn't resolve to anything and title is checked as
    #    the fallback, a class that's more specifically one of those and also
    #    happens to say "grooves" still keeps that more specific label, not Groove.
    style = _match_style(str(raw or "")) or _match_style(combined) or "Choreography"
    # 2. Apply overrides LAST, so the final rewrite wins over the base classification.
    #    Heels classes are frequently themed around another genre or prop (e.g. "Reggaeton
    #    Heels", "Chair Heels") — Heels is the actual technique being taught, so a "heels"
    #    mention overrides whatever style step 1 picked.
    if re.search(r"\bheels\b", combined.lower()):
        style = "Heels"
    return style

# Fallback keyword exclusions when exclude_keywords column is absent from DB
STUDIO_EXCLUDES = {
    "Enjoy Dance Studio": ["junior"],
    "In The Groove Studios": ["youth", "ages 3", "ages 7", "ages 10", "kids"],
    "Vell Studio SF": ["intensive"],
}


PROMPT = """You are extracting dance class schedule data from a studio website.

Extract every class listed and return a JSON array. Each class object must have:
- title: class name (string)
- dance_style: use these exact labels only — "Hip Hop", "Heels", "Jazz Funk", "K-pop", "Contemporary", "Ballet", "Salsa", "Reggaeton", "Dancehall", "Breaking", "House", "Vogue", "Turfing", "Jazz", "Chinese", "Chinese Fusion", "Pro Dance", "Popping", "Afro", "Twerk", "Krump", "Waacking", "Bachata", "Locking", "Latin", "Groove", "Choreography". Pick the closest match — Dancehall and Reggaeton are different genres, don't conflate them. Chair- and floorwork-themed classes should be labeled "Heels", not a separate style. A "Groove(s)"-titled class with no other, more specific style should be labeled "Groove", not "Choreography". Use "Choreography" as the fallback only if nothing else, including "Groove", fits. (string or null)
- instructor: teacher name (string or null)
- level: one of "beginner", "intermediate", "advanced", "begin/int", "int/adv", "all_levels" (string). Rules:
    * Check the level field first, then look for clues in the class title and description.
    * "beginner/intermediate", "beg/int", "beginner & intermediate", "Beg/Int" → "begin/int"
    * "intermediate/advanced", "int/adv", "intermediate & advanced", "Int/Adv" → "int/adv"
    * "all levels", "open", "open level" → "all_levels"
    * If nothing indicates a level, use "all_levels". Never return null.
- date: in YYYY-MM-DD format (string). Rules:
    * If a full date like "Sunday, June 28th, 2026" is given, use it directly.
    * If month+day are given (e.g. "Jul 21"), use year {year}.
    * If a relative label like "TODAY", "TOMORROW", or "THIS THURSDAY, JULY 9" is given, resolve it relative to today ({today}) — use the explicit month+day if present, otherwise compute the offset from today.
    * If only a weekday is given, resolve to the next upcoming occurrence from today ({today}).
    * For listings that show multiple dates followed by multiple times in order (e.g. "Jul 21 / Jul 28 / 8:00 PM / 8:00 PM"), pair them positionally.
- start_time: in HH:MM:SS format, 24-hour (string)
- duration_minutes: integer. Calculate from start and end times if both are shown (e.g. 6:00–7:30 PM = 90). Use the listed duration if given directly. null only if no end time or duration is shown anywhere.
- description: any extra info (string or null)
- location_name: the location/branch name e.g. "Fremont", "Cupertino" (string or null)
- location_address: the full street address if listed (string or null)
- location_city: the city extracted from the address (string or null)

Return ONLY a valid JSON array, no explanation. If no classes are found, return [].
"""

ACUITY_SKIP_CATEGORIES = ["studio rental", "studio rentals", "film rental", "bundle", "membership", "showcase", "gift certificate"]

def _scrape_acuity_categories(url: str) -> str:
    """Walk through an Acuity .as.me category-based scheduling page and collect all class date text."""
    # Ensure we navigate to the all-categories view
    base = url.split('/category/')[0].split('?')[0]
    all_cats_url = base + "/category/X19hbGxfXw%3D%3D"

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        try:
            page.goto(all_cats_url, wait_until="load", timeout=30000)
            page.wait_for_timeout(1000)

            # Extract studio location from embedded BUSINESS data
            location = page.evaluate("""() => {
                try {
                    const c = window.BUSINESS?.calendars || {};
                    return Object.keys(c).join(', ');
                } catch(e) { return ''; }
            }""") or ""

            btns = page.query_selector_all('button')
            cat_sels = [b for b in btns if b.inner_text().strip() == 'SELECT']
            n_cats = len(cat_sels)

            all_text = (location + "\n") if location else ""

            for cat_idx in range(n_cats):
                page.goto(all_cats_url, wait_until="load", timeout=30000)
                page.wait_for_timeout(800)

                btns = page.query_selector_all('button')
                cat_btns = [b for b in btns if b.inner_text().strip() == 'SELECT']
                if cat_idx >= len(cat_btns):
                    break

                cat_btns[cat_idx].click()
                page.wait_for_timeout(1000)

                cat_url = page.url
                cat_page_text = page.inner_text("body")

                # Skip non-dance categories
                if any(kw in cat_page_text.lower() for kw in ACUITY_SKIP_CATEGORIES):
                    continue
                # Skip if navigated to a non-category page (e.g. direct calendar)
                if '/category/' not in cat_url:
                    continue

                appt_btns = page.query_selector_all('button')
                appt_sels = [b for b in appt_btns if b.inner_text().strip() == 'SELECT']
                n_appts = len(appt_sels)

                for appt_idx in range(n_appts):
                    page.goto(cat_url, wait_until="load", timeout=30000)
                    page.wait_for_timeout(800)

                    appt_btns = page.query_selector_all('button')
                    appt_sel = [b for b in appt_btns if b.inner_text().strip() == 'SELECT']
                    if appt_idx >= len(appt_sel):
                        break

                    appt_sel[appt_idx].click()
                    page.wait_for_timeout(1000)

                    slot_text = page.inner_text("body")

                    # Handle "Select Calendar" / instructor selection step
                    if "Select Calendar" in slot_text or ("WITH" in slot_text[:300] and "Date & Time" not in slot_text[:300]):
                        extra_btns = page.query_selector_all('button')
                        extra_sels = [b for b in extra_btns if b.inner_text().strip() == 'SELECT']
                        if extra_sels:
                            extra_sels[0].click()
                            page.wait_for_timeout(1000)
                            slot_text = page.inner_text("body")

                    if any(m in slot_text for m in [" AM", " PM", "Today", "Tomorrow", "This week", "Next week"]):
                        all_text += "\n\n" + slot_text

            return all_text
        finally:
            page.close()
            browser.close()


def get_all_frames_text(page) -> str:
    text = page.inner_text("body")
    for frame in page.frames[1:]:
        try:
            frame.wait_for_load_state("load", timeout=5000)
            frame_text = frame.inner_text("body")
            if frame_text.strip():
                text += "\n" + frame_text
        except Exception:
            pass
    return text

def _fetch_wix_slots(base_url: str, auth_token: str, from_date: date, to_date: date, city_filter: str = None) -> str:
    """Call Wix Bookings API directly to get class slots for a date range."""
    headers = {
        "authorization": auth_token,
        "content-type": "application/json",
        "x-wix-brand": "studio",
    }
    payload = {
        "fromLocalDate": f"{from_date.isoformat()}T00:00:00",
        "toLocalDate": f"{to_date.isoformat()}T23:59:59",
        "eventFilter": {"type": "CLASS"},
        "timeZone": "America/Los_Angeles",
        "cursorPaging": {"limit": 200},
        "includeNonBookable": True,
    }
    resp = http_requests.post(
        f"{base_url}/_api/service-availability/v2/time-slots/event",
        json=payload,
        headers=headers,
        timeout=15,
    )
    if resp.status_code != 200:
        return ""
    slots = resp.json().get("timeSlots", [])
    lines = []
    for slot in slots:
        loc = slot.get("location", {})
        loc_addr = loc.get("formattedAddress", "")
        # filter by city if specified (e.g. "san jose" vs "san mateo")
        if city_filter and city_filter.lower() not in loc_addr.lower():
            continue
        title = slot.get("eventInfo", {}).get("eventTitle", "")
        start = slot.get("localStartDate", "")
        loc_name = loc.get("name", "")
        instructors = [
            res.get("name", "")
            for r in slot.get("availableResources", [])
            for res in r.get("resources", [])
        ]
        lines.append(f"{title}\n{', '.join(instructors)}\n{start[:10]} {start[11:16]}\n{loc_name}\n{loc_addr}")
    return "\n\n".join(lines)


def _scrape_linktree_calendly(url: str) -> str:
    """Load a Linktree page, follow each Calendly/Momence booking link, and collect class text."""
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        try:
            page.goto(url, wait_until="load", timeout=20000)
            page.wait_for_timeout(3000)
            # Collect all calendly.com and momence.com booking links
            links = page.query_selector_all('a[href*="calendly.com"], a[href*="momence.com"]')
            booking_urls = []
            for link in links:
                href = link.get_attribute("href") or ""
                if ("calendly.com" in href or "momence.com" in href) and href not in booking_urls:
                    booking_urls.append(href)
            print(f"  → found {len(booking_urls)} Calendly/Momence links")
            all_text = ""
            for booking_url in booking_urls:
                try:
                    page.goto(booking_url, wait_until="networkidle", timeout=20000)
                    class_text = page.inner_text("body")
                    print(f"  → booking {len(class_text)} chars: {class_text[:80].strip()!r}")
                    lower = class_text.lower()
                    if "not valid" not in lower and "already passed" not in lower:
                        all_text += "\n\n" + class_text
                except Exception as e:
                    print(f"  → booking error: {e}")
            return all_text
        finally:
            page.close()
            browser.close()


def _scrape_rae_studios(url: str, days_ahead: int = 14) -> str:
    """Rae Studios embeds a paginated Momence booking widget inside a Wix HTML iframe.
    Click "SHOW All" then page through it, collecting real class listings (date, time,
    room, style+level, instructor) until we pass the days_ahead cutoff."""
    cutoff_date = date.today() + timedelta(days=days_ahead)
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1280, "height": 3000})
        try:
            page.goto(url, wait_until="load", timeout=30000)
            page.wait_for_timeout(4000)
            target = None
            for f in page.frames:
                if f.url.startswith("https://www-raestudios-sf-com.filesusr.com/html/"):
                    try:
                        if f.query_selector('text=SHOW All'):
                            target = f
                            break
                    except Exception:
                        pass
            if not target:
                print("  → Rae Studios widget iframe not found")
                return ""

            show_all = target.query_selector('text=SHOW All')
            if show_all:
                show_all.evaluate("el => el.click()")
                page.wait_for_timeout(2500)

            all_text = ""
            cutoff_patterns = [
                cutoff_date.strftime("%B").upper() + " " + str(cutoff_date.day),
            ]
            reached_cutoff = False
            page_num = 0
            # Cap is a runaway guard only; the real stop is the cutoff date or running
            # out of "Next Page" buttons.
            while page_num < _PAGINATION_MAX_CLICKS:
                page_num += 1
                chunk = target.inner_text("body")
                all_text += "\n\n" + chunk
                print(f"  → page {page_num}: {len(chunk)} chars")
                if any(pat in chunk.upper() for pat in cutoff_patterns):
                    reached_cutoff = True
                    break
                next_btn = target.query_selector('[aria-label^="Next Page"]')
                if not next_btn:
                    break  # genuine end of schedule
                next_btn.evaluate("el => el.click()")
                page.wait_for_timeout(2000)
            if not reached_cutoff:
                print(f"  → WARNING: Rae Studios stopped after {page_num} pages "
                      f"without reaching {days_ahead}-day cutoff (may be partial)")
            return all_text
        finally:
            page.close()
            browser.close()


_EDS_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRpbGVwY3d5a3Nwc2dibGxwdGJmIiwicm9sZSI6ImFub24iLCJpYXQiOjE2NTQzNzYxNzgsImV4cCI6MTk2OTk1MjE3OH0.WCOgcOIzxgmlFFbs5Fc5AiyJb-bZyyl9m11R7gvBoxI"
_EDS_GQL_URL = "https://tilepcwykspsgbllptbf.supabase.co/graphql/v1"
_EDS_GQL_QUERY = """
query GetClasses($start: Datetime, $end: Datetime) {
  eventCollection(
    filter: {startAt: {gte: $start, lte: $end}, canceledAt: {is: NULL}, kind: {eq: "dance_class"}}
    orderBy: {startAt: AscNullsLast}
    first: 200
  ) {
    edges {
      node {
        id
        autoFinalTitle
        autoFinalSubtitle
        startAt
        autoEndAt
        durationMinute
        autoFinalTimezone
        eventMemberCollection(filter: {role: {eq: "teacher"}}) {
          edges {
            node {
              profile {
                funcGivenNameEnFirst
                funcFamilyNameEnFirst
              }
            }
          }
        }
        autoSpaceLandmark {
          funcTitleShortEnFirst
        }
        metadata {
          autoFinalTitle
        }
      }
    }
  }
}
"""

def _fetch_eds_classes(studio_id: str, days_ahead: int = 14) -> list[dict]:
    """Fetch EDS classes directly from their Supabase GraphQL API, bypassing Haiku."""
    from datetime import datetime, timedelta as _td
    today = date.today()
    cutoff = today + timedelta(days=days_ahead)
    resp = http_requests.post(
        _EDS_GQL_URL,
        json={
            "query": _EDS_GQL_QUERY,
            "variables": {
                "start": today.isoformat() + "T07:00:00+00:00",  # midnight PT (PDT = UTC-7)
                "end": cutoff.isoformat() + "T06:59:59+00:00",   # 11:59 PM PT
            },
        },
        headers={"apikey": _EDS_ANON_KEY, "Content-Type": "application/json"},
        timeout=30,
    )
    payload = resp.json()
    edges = ((payload.get("data") or {}).get("eventCollection") or {}).get("edges") or []
    classes = []
    for e in edges:
        n = e["node"]
        title_raw = n.get("autoFinalTitle") or ""
        try:
            title_en = json.loads(title_raw).get("en", title_raw)
        except Exception:
            title_en = title_raw
        class_match = re.search(r"'([^']+)'", title_en)
        class_name = class_match.group(1) if class_match else title_en
        class_name = re.split(r"\s*/\s*#\d+", class_name)[0].strip()
        teacher_match = re.match(r"\[0\]\s+(.+?)\s+(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)", title_en)
        teacher = teacher_match.group(1).strip() if teacher_match else ""
        # Use the authoritative location relation rather than guessing the city from raw
        # text — e.g. "EDS Fremont" / "Cupertino Studio C" both need to resolve to the
        # same location names ("Fremont" / "Cupertino") already used in the DB.
        landmark_raw = ((n.get("autoSpaceLandmark") or {}).get("funcTitleShortEnFirst")) or ""
        city = next((c for c in ("Fremont", "Cupertino") if c.lower() in landmark_raw.lower()), None)
        subtitle_raw = n.get("autoFinalSubtitle") or ""
        try:
            subtitle = json.loads(subtitle_raw).get("en", subtitle_raw)
            subtitle = re.sub(r"\s+\d+/\d+$", "", subtitle).strip()
        except Exception:
            subtitle = ""
        title = subtitle or class_name
        # The event's own title/subtitle is often a creative/song-based session name
        # (e.g. "One Last Time") with no style info in it at all — the actual style+level
        # ("Beginner High Heels") lives on the linked class-series metadata instead.
        category_raw = ((n.get("metadata") or {}).get("autoFinalTitle")) or ""
        try:
            category = json.loads(category_raw).get("en", category_raw)
        except Exception:
            category = category_raw
        start_utc = n.get("startAt") or ""
        duration_raw = n.get("durationMinute")
        try:
            dt_utc = datetime.fromisoformat(start_utc.replace("Z", "+00:00"))
            pt_offset = -7 if 3 <= dt_utc.month <= 11 else -8
            dt_pt = dt_utc + _td(hours=pt_offset)
            date_str = dt_pt.strftime("%Y-%m-%d")
            time_str = dt_pt.strftime("%H:%M:%S")
        except Exception:
            continue
        c = {
            "studio_id": studio_id,
            "title": title,
            "instructor": teacher or None,
            "date": date_str,
            "start_time": time_str,
            "duration_minutes": _normalize_duration(duration_raw),
            # Only the category (the class series' actual style/level) counts as a
            # signal — the session's own title is often just a creative/song name
            # (e.g. "One Last Time") and shouldn't influence style or level at all.
            "dance_style": _normalize_style(None, "", category),
            "level": _normalize_level(None, "", category),
            "description": category or None,
            "_loc_city": city,
            "_loc_address": None,
        }
        classes.append(c)
    return classes


def _fetch_healcode_widget(url: str, studio_id: str, days_ahead: int = 14) -> list[dict]:
    """Fetch a Mindbody "Healcode" branded-web-widget schedule directly via its
    load_markup JSON endpoint (e.g. https://widgets.mindbodyonline.com/widgets/schedules/<id>/load_markup).

    This is the widget a studio's own site embeds inline — distinct from (and NOT behind
    the Cloudflare bot-check that guards) the outbound "classic" Mindbody booking page
    those sites often also link to. A single GET with start_date/end_date returns the
    whole window in one shot: no Playwright, no pagination/clicking, no Cloudflare.

    The markup exposes explicit machine-readable fields (ISO datetimes, name, staff), so
    this skips Haiku entirely and regex-parses it directly — same rationale as the EDS
    direct-API path: more reliable than trusting an LLM to infer dates from prose, and
    free of token/chunking limits.
    """
    today = date.today()
    cutoff = today + timedelta(days=days_ahead)
    resp = http_requests.get(
        url,
        params={"options[start_date]": today.isoformat(), "options[end_date]": cutoff.isoformat()},
        headers={"User-Agent": "Mozilla/5.0"},
        timeout=30,
    )
    html = resp.json().get("class_sessions", "")
    classes = []
    for chunk in re.split(r'(?=<div class="bw-session" id=)', html)[1:]:
        start_m = re.search(r'class="hc_starttime" datetime="(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})"', chunk)
        end_m = re.search(r'class="hc_endtime" datetime="\d{4}-\d{2}-\d{2}T(\d{2}):(\d{2})"', chunk)
        name_m = re.search(
            r'bw-session__name">\s*(?:<span class="bw-session__type"[^>]*>([^<]*)</span>)?\s*([^<\n]+)', chunk)
        staff_m = re.search(r'bw-session__staff"[^>]*>\s*([^<\n]+)', chunk)
        if not start_m or not name_m:
            continue
        title = ((name_m.group(1) or "") + (name_m.group(2) or "")).strip()
        if not title or "online" in title.lower():
            continue  # in-person only — the widget lists an "(Online)" twin of every class
        date_str, sh, sm = start_m.group(1), int(start_m.group(2)), int(start_m.group(3))
        duration = None
        if end_m:
            eh, em = int(end_m.group(1)), int(end_m.group(2))
            duration = (eh * 60 + em) - (sh * 60 + sm)
        instructor = staff_m.group(1).strip() if staff_m else None
        classes.append({
            "studio_id": studio_id,
            "title": title,
            "instructor": instructor or None,
            "date": date_str,
            "start_time": f"{sh:02d}:{sm:02d}:00",
            "duration_minutes": _normalize_duration(duration),
            # Not text-matched: level-graded titles like "Intermediate/Advanced (In
            # Person)" don't contain the word "ballet" at all, but this studio teaches
            # nothing else, so the style is a known constant rather than inferred.
            "dance_style": "Ballet",
            "level": _normalize_level(None, title, ""),
            "description": None,
        })
    return classes


# Mindbody's day-tile widget repeats ~150 chars of identical nav chrome ("My
# Account...Full Calendar...Today\n13\nTue\n14...") before every single day's content.
# That's a quarter or more of the total captured text on a 14-day pull, and it's pure
# noise for date extraction (the real date always comes from the explicit day header
# right after it, e.g. "Monday, Jul 13") — so strip everything before that header out
# of each day's capture. Cuts total text size and removes a likely source of Haiku
# date-attribution errors on studios with many days of near-duplicate boilerplate.
_DAY_HEADER_RE = re.compile(
    r"(?:Sunday|Monday|Tuesday|Wednesday|Thursday|Friday|Saturday), "
    r"(January|February|March|April|May|June|July|August|September|October|November|December|"
    r"Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec) (\d{1,2})"
)

_MONTH_NUM = {
    "January": 1, "Jan": 1, "February": 2, "Feb": 2, "March": 3, "Mar": 3,
    "April": 4, "Apr": 4, "May": 5, "June": 6, "Jun": 6, "July": 7, "Jul": 7,
    "August": 8, "Aug": 8, "September": 9, "Sep": 9, "October": 10, "Oct": 10,
    "November": 11, "Nov": 11, "December": 12, "Dec": 12,
}

# Marker we inject ourselves at each day-tile capture, once we've deterministically
# resolved its date from the page's own header via regex + arithmetic. Distinctive
# enough (unlike free-form prose) that it can never appear by accident in any other
# studio's scraped text, so splitting on it later is unambiguous and side-effect-free
# for every other fetch path.
_DAY_TAG_RE = re.compile(r"===CLASSDATE:(\d{4}-\d{2}-\d{2})===")


def _resolve_header_date(month_name: str, day_num: int, today: date) -> date:
    month = _MONTH_NUM[month_name]
    year = today.year
    candidate = date(year, month, day_num)
    # A 14-day pull is always near "today" -- if the naive same-year date lands far in
    # the past (e.g. scraping in late December for early January classes), it's really
    # next year.
    if candidate < today - timedelta(days=180):
        candidate = date(year + 1, month, day_num)
    return candidate


def _strip_nav_boilerplate(text: str) -> str:
    m = _DAY_HEADER_RE.search(text)
    return text[m.start():] if m else text


def _strip_and_tag_day(text: str, today: date) -> str:
    """Strip the nav boilerplate (as _strip_nav_boilerplate does) and, since we're
    already looking at the day header to do that, resolve its date ourselves and
    prefix the result with an explicit ===CLASSDATE:YYYY-MM-DD=== marker. Downstream,
    Haiku is never asked to compute/infer this date at all -- _parse_raw_by_day
    splits on the marker and force-sets it on every class in that segment, so a
    misread of the header text can no longer misattribute a day's classes to the
    wrong date the way it did for On One Studio on 2026-07-12/13."""
    m = _DAY_HEADER_RE.search(text)
    if not m:
        return text
    resolved = _resolve_header_date(m.group(1), int(m.group(2)), today)
    return f"===CLASSDATE:{resolved.isoformat()}===\n" + text[m.start():]


def fetch_page_text(url: str, days_ahead: int = 1) -> str:
    if "my.eds.dance" in url:
        return ""  # EDS handled directly in _fetch_studio via _fetch_eds_classes

    # Acuity .as.me URLs use a multi-step category click-through
    if ".as.me" in url:
        return _scrape_acuity_categories(url)

    # Linktree pages: follow Calendly booking links
    if "linktr.ee" in url:
        return _scrape_linktree_calendly(url)

    # Rae Studios embeds a paginated Momence widget in a Wix iframe
    if "raestudios-sf.com" in url:
        return _scrape_rae_studios(url, days_ahead=days_ahead)

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        try:
            # intercept Wix API auth token if present
            wix_auth = [None]
            wix_base = [None]

            def on_request(req):
                if "_api" in req.url:
                    token = req.headers.get("authorization")
                    if token and not wix_auth[0]:
                        wix_auth[0] = token
                        parsed = urlparse(req.url)
                        wix_base[0] = f"{parsed.scheme}://{parsed.netloc}"

            page.on("request", on_request)

            page.goto(url, wait_until="load", timeout=30000)
            page.wait_for_timeout(1500)
            all_text = _strip_nav_boilerplate(get_all_frames_text(page))

            # for Wix sites: use the API directly to get additional weeks
            if wix_auth[0] and days_ahead > 1:
                today = date.today()
                # infer city from URL path (e.g. calendar-san-jose → "san jose")
                path = urlparse(url).path.lower()
                city_filter = None
                for segment in path.split("/"):
                    if segment.startswith("calendar-"):
                        city_filter = segment[len("calendar-"):].replace("-", " ")
                extra = _fetch_wix_slots(wix_base[0], wix_auth[0],
                                         today + timedelta(days=7),
                                         today + timedelta(days=days_ahead),
                                         city_filter=city_filter)
                if extra:
                    all_text += "\n\n" + extra
                    print(f"  → added Wix API data for days 8-{days_ahead} (city: {city_filter})")
                return all_text

            if days_ahead <= 1:
                return all_text

            days_collected = 1
            first_week = True
            prev_day_text = all_text

            # Mindbody widgets use div[role="button"] for day tiles and for the
            # Previous/Next/Open-calendar controls alike; excluded by aria-label so
            # only actual day tiles remain. Defined once (not re-built per iteration
            # or duplicated between the day-tile collection and the signature check
            # below) so the two can never drift out of sync with each other.
            def _day_tile_signature():
                # Falls back to iframes like the "Next" button lookup below does --
                # a widget whose Next button lives in an iframe has its day tiles
                # there too, and a main-page-only query would return "" before and
                # after every click, always reporting (falsely) that nothing changed.
                sig = []
                for frame in [page] + list(page.frames):
                    try:
                        btns = frame.query_selector_all('[role="button"]')
                    except Exception:
                        continue
                    for b in btns:
                        if (b.get_attribute("aria-label") or "").lower() in _NAV_LABELS:
                            continue
                        try:
                            sig.append(b.inner_text().strip())
                        except Exception:
                            pass
                return "|".join(sig)

            while days_collected < days_ahead:
                all_btns = page.query_selector_all('[role="button"]')
                day_tiles = [b for b in all_btns
                             if (b.get_attribute("aria-label") or "").lower() not in _NAV_LABELS]
                if first_week:
                    # first tile is already selected; skip it. Now that we know for
                    # certain this studio uses the Mindbody day-tile widget, retag the
                    # day-1 content captured before the loop with its own resolved-date
                    # marker too, for consistency with every day captured below.
                    all_text = _strip_and_tag_day(all_text, date.today())
                    prev_day_text = all_text
                    day_tiles = list(day_tiles)[1:]
                    first_week = False

                if day_tiles:
                    for tile in day_tiles:
                        if days_collected >= days_ahead:
                            break
                        try:
                            tile.click(force=True)
                            page.wait_for_timeout(700)
                            day_text = _strip_and_tag_day(get_all_frames_text(page), date.today())
                            # Verify the tile click actually swapped in a new day
                            # instead of trusting the fixed wait -- this is the same
                            # stale-DOM race the Next-button check below guards
                            # against, just on the more frequently exercised path
                            # (every tile in every week, not just once per week), so
                            # leaving it unguarded here left the biggest source of
                            # the duplicate-day-capture race for _add_deduped to
                            # silently clean up after rather than catch at the source.
                            for _ in range(3):
                                if day_text != prev_day_text:
                                    break
                                page.wait_for_timeout(350)
                                day_text = _strip_and_tag_day(get_all_frames_text(page), date.today())
                            else:
                                print(f"  → WARNING: day content unchanged after tile click "
                                      f"(possible stale-tile race) at day {days_collected + 1}, proceeding anyway")
                            print(f"  → day {days_collected + 1}: {len(day_text)} chars")
                            all_text += "\n" + day_text
                            days_collected += 1
                            prev_day_text = day_text
                        except Exception as e:
                            # A stale ElementHandle (the same class of race the Next-click
                            # wait below guards against) raises here instead of silently
                            # re-rendering old content -- that means this day is skipped
                            # outright, not duplicated, which _parse_raw_by_day's dedup
                            # can't detect or repair (nothing to drop, just a hole). Log it
                            # so a dropped day is visible instead of indistinguishable from
                            # a day that genuinely has no classes.
                            print(f"  → day tile click failed (day {days_collected + 1} of {days_ahead}): {e}")

                    if days_collected >= days_ahead:
                        break

                # Try "More times" button (Acuity list view) — use LAST button (loads future)
                # Extract BOOK button aria-labels: compact, info-dense, ~130 chars each
                def _acuity_book_labels(pg):
                    labels = []
                    for frame in [pg] + list(pg.frames):
                        try:
                            btns = frame.query_selector_all('[aria-label^="Book "]')
                            labels += [b.get_attribute("aria-label") for b in btns if b.get_attribute("aria-label")]
                        except Exception:
                            pass
                    return "\n".join(labels)

                more_btns = page.query_selector_all('[aria-label="More times"]')
                more_btn = more_btns[-1] if more_btns else None
                if more_btn:
                    cutoff_date = date.today() + timedelta(days=14)
                    cutoff_pattern = (
                        cutoff_date.strftime("%B") + r"\s+" + str(cutoff_date.day) + r"(?:st|nd|rd|th)"
                    )
                    # Replace full page text with compact book labels for initial state
                    all_text = _acuity_book_labels(page)
                    clicks = 0
                    reached_cutoff = False
                    # Cap is a runaway guard only — the real stop is reaching the cutoff
                    # date. Set well above what 14 days needs so we don't truncate early
                    # if a studio has many classes per "More times" batch.
                    while more_btn and clicks < _PAGINATION_MAX_CLICKS:
                        more_btn.click(force=True)
                        page.wait_for_timeout(800)
                        clicks += 1
                        batch = _acuity_book_labels(page)
                        all_text += "\n" + batch
                        if re.search(cutoff_pattern, batch):
                            reached_cutoff = True
                            break
                        more_btns = page.query_selector_all('[aria-label="More times"]')
                        more_btn = more_btns[-1] if more_btns else None
                    days_collected = 14
                    if not reached_cutoff:
                        print(f"  → WARNING: 'More times' stopped after {clicks} clicks "
                              f"without reaching {days_ahead}-day cutoff (may be partial)")
                    else:
                        print(f"  → clicked More times x{clicks} (reached cutoff)")
                    break

                # advance to next week / next page
                next_btn = page.query_selector('[aria-label="Next"]')
                if not next_btn:
                    for frame in page.frames[1:]:
                        try:
                            next_btn = frame.query_selector('[aria-label="Next"]')
                            if next_btn:
                                break
                        except Exception:
                            pass
                if not next_btn:
                    print(f"  → no Next button, stopping at day {days_collected}")
                    break

                # Verify the week actually advanced instead of trusting a fixed wait.
                # A stale day-tile signature after this click is the suspected root
                # cause of the duplicate-day-capture bug that _parse_raw_by_day's
                # dedup (_add_deduped / _class_identity_key) exists to clean up after
                # the fact -- catching it here instead avoids the wasted re-click,
                # re-render, and duplicate per-day Haiku calls that downstream dedup
                # alone can't prevent, only mask.
                before_signature = _day_tile_signature()
                next_btn.click(force=True)
                for _ in range(5):
                    page.wait_for_timeout(400)
                    if _day_tile_signature() != before_signature:
                        # Tiles can re-render progressively (e.g. a selection
                        # highlight updates before the date labels do) -- one more
                        # short wait so a signature change caught mid-transition
                        # doesn't send the day-tile loop after tiles that haven't
                        # finished settling yet.
                        page.wait_for_timeout(250)
                        break
                else:
                    print(f"  → WARNING: day tiles unchanged after clicking Next "
                          f"(possible stale-tiles race) at day {days_collected}, proceeding anyway")

            return all_text
        finally:
            page.close()
            browser.close()

_CHUNK_LIMIT = 5000

def _parse_raw(page_text: str, studio_id: str, studio_name: str) -> list[dict]:
    """Call Claude Haiku and normalize fields. Chunks large inputs to stay within output token limit."""
    if len(page_text) > _CHUNK_LIMIT:
        # Split at blank-line (paragraph) boundaries so a single class's text block
        # is never cut in half — falls back to a line boundary if no blank line is in range.
        seen: set[tuple] = set()
        result: list[dict] = []
        pos = 0
        while pos < len(page_text):
            end = min(pos + _CHUNK_LIMIT, len(page_text))
            if end < len(page_text):
                boundary = page_text.rfind("\n\n", pos, end)
                if boundary <= pos:
                    boundary = page_text.rfind("\n", pos, end)
                if boundary > pos:
                    end = boundary
            chunk = page_text[pos:end].strip()
            pos = end + 1
            if not chunk:
                continue
            try:
                for c in _parse_raw(chunk, studio_id, studio_name):
                    key = _class_identity_key(c)
                    if key not in seen:
                        seen.add(key)
                        result.append(c)
            except Exception as e:
                print(f"  chunk parse error: {e}")
        return result

    today = date.today().isoformat()
    year = date.today().year
    message = _get_anthropic().messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=8192,
        messages=[{
            "role": "user",
            "content": PROMPT.format(today=today, year=year) + "\n\n" + page_text
        }]
    )
    raw = message.content[0].text.strip()
    if raw.startswith("```"):
        raw = raw.split("```")[1]
        if raw.startswith("json"):
            raw = raw[4:]
    try:
        classes = json.loads(raw)
    except (json.JSONDecodeError, ValueError) as e:
        # A malformed model response shouldn't sink the whole studio's parse — log and
        # skip this (chunk of) input. Chunked callers still get every other chunk.
        print(f"  Haiku returned non-JSON, skipping: {e}; raw[:120]={raw[:120]!r}")
        return []
    if not isinstance(classes, list):
        print(f"  Haiku returned non-list JSON ({type(classes).__name__}), skipping")
        return []
    result = []
    for c in classes:
        if not c.get("start_time"):
            continue
        c["studio_id"] = studio_id
        c["level"] = _normalize_level(c.get("level"), c.get("title", ""), c.get("description", ""))
        c["dance_style"] = _normalize_style(c.get("dance_style"), c.get("title", ""), c.get("description", ""))
        c["duration_minutes"] = _normalize_duration(c.get("duration_minutes"))
        c.pop("location_name", None)
        # Keep _loc_city/_loc_address for sequential resolution phase
        c["_loc_city"] = c.pop("location_city", None)
        c["_loc_address"] = c.pop("location_address", None)
        result.append(c)
    return result


def _inject_location_hint(t: str, city_hint: str) -> str:
    """Tag one schedule_url's fetched text with its resolved city so Haiku assigns
    the right location_city, in a way that survives _parse_raw_by_day's marker-based
    splitting once _fetch_studio concatenates every location's text together.

    _parse_raw_by_day splits the full concatenated blob on ===CLASSDATE=== markers
    into per-day segments running from one marker's end to the next marker's start.
    A hint placed as a plain prefix BEFORE this url's own markers would fall in that
    gap and get sliced into the TAIL of the PRECEDING url's last-day segment instead
    of into this url's own days -- every location but the first would then parse
    with no hint at all, and the location before it would parse with the wrong one.
    Inserting the hint right after each marker instead keeps it inside this url's
    own per-day segments, however many locations get concatenated in whatever order.

    Falls back to a plain prefix when `t` has no markers at all (single-day fetch,
    or a fetch path that never tags days) -- there's no splitting to survive, so a
    prefix is safe and there's nothing to insert after."""
    tag_line = f"[Location: {city_hint}, CA]\n"
    if _DAY_TAG_RE.search(t):
        return _DAY_TAG_RE.sub(lambda m: m.group(0) + "\n" + tag_line, t)
    return tag_line + t


def _parse_raw_by_day(page_text: str, studio_id: str, studio_name: str) -> list[dict]:
    """Like _parse_raw, but for text carrying our own ===CLASSDATE:YYYY-MM-DD===
    markers (see _strip_and_tag_day) -- splits on those markers first and parses each
    day in isolation, then force-sets the date on every class in that segment to the
    marker's value, ignoring whatever Haiku returns for "date" entirely. Removes date
    attribution as something the model can get wrong, rather than just reducing the
    odds of it (the boilerplate strip alone did the latter, which caught neither of
    the two On One Studio incidents on 2026-07-12/13 -- one dropped a day, the other
    misattributed one day's classes onto a different day).

    Falls back to plain _parse_raw unchanged when no markers are present (every other
    fetch path -- Acuity, Linktree, Rae, Wix -- never produces this marker, so this is
    a no-op there).

    Deduped by _class_identity_key (date, start_time, normalized title, normalized
    location): if the day-tile pagination loop ever re-captures the same calendar
    day twice (e.g. a stale-tiles race right after clicking "Next" to advance a
    week, before the new week has finished rendering), that day now gets two
    markers and gets parsed twice. Concatenating everything into one Haiku call
    used to silently absorb that kind of exact duplication; doing per-day calls no
    longer does, so two classes can come out with an identical id and break the ON
    CONFLICT DO UPDATE upsert (a real failure hit on Young Reach Dance Studio on
    2026-07-15: "ON CONFLICT DO UPDATE command cannot affect row a second time").
    Dropping the repeat here, at the same identity _stable_class_id already uses
    for uniqueness (see _class_identity_key), is a direct fix regardless of what
    causes the re-capture.

    _class_identity_key's location component is what keeps two different locations'
    classes from colliding here: _fetch_studio concatenates every one of a
    multi-location studio's schedule_urls into a single all_text blob before the one
    _parse_raw_by_day call that applies this dedup -- without a location component,
    two different locations legitimately offering the same class at the same time
    would look like one location's class captured twice, and the second would be
    silently (if logged) discarded as a false duplicate instead of kept as the
    distinct class it is."""
    marker_positions = list(_DAY_TAG_RE.finditer(page_text))
    if not marker_positions:
        return _parse_raw(page_text, studio_id, studio_name)

    seen: set[tuple] = set()
    result = []

    def _add_deduped(classes):
        for c in classes:
            key = _class_identity_key(c)
            if key in seen:
                print(f"  → dropped duplicate day-capture: {c.get('date')} {c.get('start_time')} "
                      f"{c.get('title')!r} ({c.get('_loc_city') or 'no location'})")
                continue
            seen.add(key)
            result.append(c)

    # Any text before the first marker (should be empty in practice) has no resolved
    # date to force -- parse it the old way rather than silently drop it.
    if page_text[:marker_positions[0].start()].strip():
        _add_deduped(_parse_raw(page_text[:marker_positions[0].start()], studio_id, studio_name))

    for i, m in enumerate(marker_positions):
        seg_start = m.end()
        seg_end = marker_positions[i + 1].start() if i + 1 < len(marker_positions) else len(page_text)
        day_classes = _parse_raw(page_text[seg_start:seg_end], studio_id, studio_name)
        resolved_date = m.group(1)
        for c in day_classes:
            c["date"] = resolved_date
        _add_deduped(day_classes)
    return result


_DAYS_AHEAD = 14

def _fetch_studio(studio: dict) -> tuple[str, list[dict], "str | None"]:
    """Phase 1 (parallel): fetch pages + parse + normalize. No DB calls.

    Returns (studio_id, classes, covered_through). `covered_through` is the furthest
    date (YYYY-MM-DD) this scrape can vouch for, and drives how much the parent prunes:
      * None            → the fetch/parse failed OR produced nothing trustworthy; the
                          parent must leave ALL existing rows untouched.
      * "YYYY-MM-DD"    → `classes` is authoritative for [today, that date]. The parent
                          refreshes that range and leaves later-dated rows alone, so a
                          run that only paginated part of the window never erases a
                          previous, more-complete run's later weeks.

    A studio genuinely having zero upcoming classes for two weeks is effectively
    impossible, so an empty parse is treated as an untrustworthy fetch (None) rather
    than a signal to clear the studio — erring toward never destroying good data.
    """
    sid = studio["id"]
    name = studio["name"]
    tag = sid[:8]
    today_str = date.today().isoformat()
    cutoff = (date.today() + timedelta(days=_DAYS_AHEAD)).isoformat()
    db_exclude = studio.get("exclude_keywords") or []
    code_exclude = STUDIO_EXCLUDES.get(name, [])
    exclude = [kw.lower() for kw in (db_exclude or code_exclude)]

    def _apply_exclude(classes):
        if not exclude:
            return classes
        return [c for c in classes if not any(
            kw in ((c.get("title") or "") + " " + (c.get("description") or "")).lower()
            for kw in exclude
        )]

    def _report(classes, coverage):
        # Turn coverage into a human-readable N/14 days line and a status word.
        if coverage is None:
            status = "FAILED (existing data kept)"
            days = 0
        else:
            days = (date.fromisoformat(coverage) - date.today()).days + 1
            if days >= _DAYS_AHEAD:
                status = "complete"
            else:
                status = f"PARTIAL — reached {coverage}, short of {cutoff}"
        print(f"[{tag}] {name}: {len(classes)} classes, coverage {max(days, 0)}/{_DAYS_AHEAD} days ({status})")

    try:
        urls = studio.get("schedule_urls") or []

        # EDS: skip Haiku — parse GraphQL API directly to avoid token-limit failures.
        # The EDS API returns the whole [today, cutoff] window in one call, so a
        # non-empty result is authoritative through the full cutoff.
        if any("my.eds.dance" in u for u in urls):
            classes = _apply_exclude(_fetch_eds_classes(sid, days_ahead=_DAYS_AHEAD))
            coverage = cutoff if classes else None
            _report(classes, coverage)
            return sid, classes, coverage

        # Healcode (Mindbody branded web widget): skip Haiku — the widget's own
        # load_markup endpoint returns the whole [today, cutoff] window in one call with
        # explicit machine-readable fields, so a non-empty result is authoritative
        # through the full cutoff, same as EDS above.
        if any("widgets.mindbodyonline.com/widgets/schedules" in u for u in urls):
            classes = _apply_exclude(_fetch_healcode_widget(urls[0], sid, days_ahead=_DAYS_AHEAD))
            coverage = cutoff if classes else None
            _report(classes, coverage)
            return sid, classes, coverage

        all_text = ""
        for url in urls:
            t = fetch_page_text(url, days_ahead=_DAYS_AHEAD)
            print(f"[{tag}] {name}: {url} ({len(t)} chars)")
            # Inject city hint from URL path so Claude Haiku assigns correct location_city
            from urllib.parse import urlparse as _urlparse
            path_seg = _urlparse(url).path.lower().strip("/").split("/")[-1]
            if "calendar-" in path_seg:
                city_hint = path_seg.replace("calendar-", "").replace("-", " ").title()
                all_text += "\n\n" + _inject_location_hint(t, city_hint)
            else:
                all_text += "\n\n" + t
        all_text = all_text.strip()
        if not all_text:
            # A working schedule page always has text; empty means the fetch failed.
            _report([], None)
            return sid, [], None
        classes = _parse_raw_by_day(all_text, sid, name)
        classes = [c for c in classes if today_str <= (c.get("date") or "") <= cutoff]
        classes = _apply_exclude(classes)
        # Coverage watermark = furthest date we actually parsed. Empty parse → None
        # (preserve existing data); otherwise trust only up to the last date we saw.
        coverage = _max_class_date(classes)
        _report(classes, coverage)
        return sid, classes, coverage
    except Exception as e:
        import traceback
        print(f"[{tag}] {name}: ERROR {e}")
        traceback.print_exc()
        return sid, [], None


def _write_studio(studio: dict, classes: list[dict], covered_through: str):
    """Phase 2 (sequential): resolve locations then write classes to DB.

    `covered_through` is the furthest date this scrape vouches for; it scopes the
    prune in replace_future_classes so later-dated rows from a more-complete prior
    run are never erased by a partial run."""
    sid = studio["id"]
    name = studio["name"]
    tag = sid[:8]
    resolved = []
    # Process classes with an explicit city first, so if this studio has no pre-existing
    # location yet, get_or_create_location() creates one before any class falls back to
    # get_default_location() — otherwise the fallback can cache a stale "no location"
    # result from before the real one existed.
    for c in sorted(classes, key=lambda c: c.get("_loc_city") is None):
        c["id"] = _stable_class_id(sid, c)
        loc_city = c.pop("_loc_city", None)
        loc_address = c.pop("_loc_address", None)
        if loc_city:
            c["location_id"] = get_or_create_location(sid, name, loc_city, loc_address)
        else:
            if sid not in _default_location_cache:
                _default_location_cache[sid] = get_default_location(sid)
            c["location_id"] = _default_location_cache[sid]
        resolved.append(c)
    replace_future_classes(sid, resolved, covered_through)
    print(f"[{tag}] {name}: {len(resolved)} classes saved (through {covered_through})")


_STUDIO_TIMEOUT_SECONDS = 240
_STUDIO_MAX_ATTEMPTS = 2


def _fetch_studio_into_queue(studio: dict, q: "mp.Queue"):
    q.put(_fetch_studio(studio))


def _fetch_studio_with_timeout(studio: dict) -> tuple[str, list[dict], "str | None"]:
    """Run _fetch_studio in its own subprocess with a hard timeout and one retry.
    A thread can't be forcibly killed if Playwright/network calls hang, so a stuck
    fetch would otherwise block forever and leak a browser process. A subprocess can
    be terminated outright, guaranteeing nothing dangles past this call.

    Returns the child's (sid, classes, covered_through) on success. Every failure here
    (timeout, crash, no result, all attempts exhausted) returns covered_through=None so
    the parent preserves the studio's existing rows rather than clearing them."""
    tag = studio["id"][:8]
    ctx = mp.get_context("spawn")
    for attempt in range(1, _STUDIO_MAX_ATTEMPTS + 1):
        q = ctx.Queue()
        p = ctx.Process(target=_fetch_studio_into_queue, args=(studio, q))
        p.start()
        p.join(_STUDIO_TIMEOUT_SECONDS)
        if p.is_alive():
            print(f"[{tag}] {studio['name']}: attempt {attempt} timed out after "
                  f"{_STUDIO_TIMEOUT_SECONDS}s, killing worker process")
            p.terminate()
            p.join(5)
            if p.is_alive():
                p.kill()
                p.join()
        elif p.exitcode != 0:
            print(f"[{tag}] {studio['name']}: attempt {attempt} worker crashed (exit code {p.exitcode})")
        else:
            try:
                return q.get_nowait()
            except Exception:
                print(f"[{tag}] {studio['name']}: attempt {attempt} produced no result")
        q.close()
        q.join_thread()
    print(f"[{tag}] {studio['name']}: all {_STUDIO_MAX_ATTEMPTS} attempts failed, leaving existing data untouched")
    return studio["id"], [], None


# Default concurrency. Each worker spawns a subprocess that launches a full Chromium
# browser (~300-700 MB + several processes), so the real footprint is many times this
# number. 4 is safe on a 2-core/7 GB CI runner; override with SCRAPE_CONCURRENCY on a
# larger machine.
_DEFAULT_CONCURRENCY = 4

def _concurrency_limit() -> int:
    try:
        n = int(os.environ.get("SCRAPE_CONCURRENCY", _DEFAULT_CONCURRENCY))
    except ValueError:
        n = _DEFAULT_CONCURRENCY
    return max(1, n)

def scrape_all(studios: list[dict]):
    # Fetch + parse all studios in parallel (each in its own timeout-guarded subprocess),
    # writing each studio's result to the DB as soon as it's ready rather than waiting
    # for the slowest one — one stuck studio no longer delays or blocks everyone else's data.
    if not studios:
        print("No studios to scrape.")
        return
    # max_workers must be >= 1 (ThreadPoolExecutor(0) raises) and no larger than the
    # number of studios; the env-tunable limit caps memory/CPU on small machines.
    max_workers = min(len(studios), _concurrency_limit())
    cutoff = (date.today() + timedelta(days=_DAYS_AHEAD)).isoformat()
    complete, partial, failed = [], [], []  # studio names, for the end-of-run summary
    with ThreadPoolExecutor(max_workers=max_workers) as executor:
        future_to_studio = {executor.submit(_fetch_studio_with_timeout, s): s for s in studios}
        for future in as_completed(future_to_studio):
            studio = future_to_studio[future]
            tag = studio["id"][:8]
            name = studio["name"]
            # Guard the whole body: a failure retrieving one studio's result (e.g. the
            # OS refusing to spawn another process under load) must not abort the loop
            # and skip every remaining studio's write.
            try:
                sid, classes, covered_through = future.result()
                if covered_through is None:
                    # Fetch/parse failed or produced nothing trustworthy — leave the
                    # studio's existing rows in place rather than wiping them.
                    print(f"[{tag}] {name}: not trustworthy, keeping existing data")
                    failed.append(name)
                    continue
                # covered_through is a date: `classes` is authoritative for
                # [today, covered_through]. Prune + upsert only within that range.
                _write_studio(studio, classes, covered_through)
                (complete if covered_through >= cutoff else partial).append(name)
            except Exception as e:
                print(f"[{tag}] {name}: FAILED, skipping ({e})")
                failed.append(name)

    # Run summary — makes silent partial/failed studios visible at a glance.
    print(
        f"\nScrape summary: {len(complete)} complete, {len(partial)} partial, "
        f"{len(failed)} failed (of {len(studios)} studios)."
    )
    if partial:
        print(f"  PARTIAL (didn't reach {cutoff}): {', '.join(sorted(partial))}")
    if failed:
        print(f"  FAILED (kept existing data): {', '.join(sorted(failed))}")
