import json
import requests as http_requests
import anthropic
from datetime import date, timedelta
from urllib.parse import urlparse
from concurrent.futures import ThreadPoolExecutor, as_completed
from playwright.sync_api import sync_playwright
from db import get_or_create_location, replace_future_classes, get_default_location

_default_location_cache = {}  # studio_id -> Optional[str]

_anthropic = anthropic.Anthropic()

_LEVEL_MAP = {
    "open": "all_levels",
    "all levels": "all_levels",
    "all": "all_levels",
}
_VALID_LEVELS = {"beginner", "intermediate", "advanced", "begin/int", "int/adv", "all_levels"}

_STYLE_MAP = {
    "hip-hop": "Hip Hop",
    "hiphop": "Hip Hop",
    "jazz funk": "Jazz Funk",
    "jazzfunk": "Jazz Funk",
    "jazz-funk": "Jazz Funk",
    "k-pop": "K-pop",
    "kpop": "K-pop",
    "k pop": "K-pop",
    "k-Pop": "K-pop",
    "house dance": "House",
    "pro dance": "Pro Dance",
}
_VALID_STYLES = {
    "Hip Hop", "Heels", "Jazz Funk", "K-pop", "Contemporary", "Ballet",
    "Salsa", "Reggaeton", "Breaking", "House", "Vogue", "Turfing",
    "Floorwork", "Chair", "Jazz", "Chinese", "Chinese Fusion", "Pro Dance", "Choreography",
}

def _normalize_level(raw, title: str = "", description: str = "") -> str:
    # Combine level field + title + description for clue detection
    combined = " ".join(filter(None, [str(raw or ""), title, description])).lower()
    if not combined.strip():
        return "all_levels"
    s = str(raw or "").strip().lower()
    if s in _LEVEL_MAP:
        return _LEVEL_MAP[s]
    # Combo levels first (order matters — check before single levels)
    if ("int" in combined or "inter" in combined) and "adv" in combined:
        return "int/adv"
    if "beg" in combined and ("int" in combined or "inter" in combined):
        return "begin/int"
    if s in _VALID_LEVELS:
        return s
    if "beg" in combined:
        return "beginner"
    if "adv" in combined:
        return "advanced"
    if "inter" in combined or s == "int":
        return "intermediate"
    return "all_levels"

def _normalize_duration(raw) -> "int | None":
    if raw is None:
        return None
    try:
        mins = int(raw)
        return mins if 15 <= mins <= 240 else None
    except (ValueError, TypeError):
        return None

def _normalize_style(raw, title: str = "", description: str = "") -> str:
    s = str(raw or "").strip()
    lower = s.lower()
    if lower in _STYLE_MAP:
        return _STYLE_MAP[lower]
    if s in _VALID_STYLES:
        return s
    # Derive from title + description if raw didn't match
    combined = " ".join(filter(None, [title, description])).lower()
    for keyword, label in [
        ("hip hop", "Hip Hop"), ("hiphop", "Hip Hop"), ("hip-hop", "Hip Hop"),
        ("jazz funk", "Jazz Funk"), ("jazzfunk", "Jazz Funk"),
        ("k-pop", "K-pop"), ("kpop", "K-pop"), ("k pop", "K-pop"),
        ("heels", "Heels"), ("reggaeton", "Reggaeton"), ("salsa", "Salsa"),
        ("ballet", "Ballet"), ("contemporary", "Contemporary"),
        ("breaking", "Breaking"), ("house", "House"), ("vogue", "Vogue"),
        ("turfing", "Turfing"), ("floorwork", "Floorwork"), ("chair", "Chair"),
        ("jazz", "Jazz"), ("chinese", "Chinese"), ("pro dance", "Pro Dance"),
    ]:
        if keyword in combined:
            return label
    return "Choreography"

# Fallback keyword exclusions when exclude_keywords column is absent from DB
STUDIO_EXCLUDES = {
    "Enjoy Dance Studio": ["junior"],
    "In The Groove Studios": ["youth", "ages 3", "ages 7", "ages 10", "kids"],
}


PROMPT = """You are extracting dance class schedule data from a studio website.

Extract every class listed and return a JSON array. Each class object must have:
- title: class name (string)
- dance_style: use these exact labels only — "Hip Hop", "Heels", "Jazz Funk", "K-pop", "Contemporary", "Ballet", "Salsa", "Reggaeton", "Breaking", "House", "Vogue", "Turfing", "Floorwork", "Chair", "Jazz", "Chinese", "Chinese Fusion", "Pro Dance", "Choreography". Pick the closest match. Use "Choreography" as the fallback if none fit. (string or null)
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
    """Load a Linktree page, follow each Calendly booking link, and collect class text."""
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        try:
            page.goto(url, wait_until="load", timeout=20000)
            page.wait_for_timeout(3000)
            # Collect all calendly.com links
            links = page.query_selector_all('a[href*="calendly.com"]')
            calendly_urls = []
            for link in links:
                href = link.get_attribute("href") or ""
                if "calendly.com" in href and href not in calendly_urls:
                    calendly_urls.append(href)
            print(f"  → found {len(calendly_urls)} Calendly links")
            all_text = ""
            for cal_url in calendly_urls:
                try:
                    page.goto(cal_url, wait_until="networkidle", timeout=20000)
                    cal_text = page.inner_text("body")
                    print(f"  → calendly {len(cal_text)} chars: {cal_text[:80].strip()!r}")
                    if "not valid" not in cal_text.lower():
                        all_text += "\n\n" + cal_text
                except Exception as e:
                    print(f"  → calendly error: {e}")
            return all_text
        finally:
            page.close()
            browser.close()


def fetch_page_text(url: str, days_ahead: int = 1) -> str:
    # Acuity .as.me URLs use a multi-step category click-through
    if ".as.me" in url:
        return _scrape_acuity_categories(url)

    # Linktree pages: follow Calendly booking links
    if "linktr.ee" in url:
        return _scrape_linktree_calendly(url)

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
            all_text = get_all_frames_text(page)

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

            while days_collected < days_ahead:
                # Mindbody widgets use div[role="button"] for day tiles
                day_tiles = page.query_selector_all('[role="button"]')
                if first_week:
                    # first tile is already selected; skip it
                    day_tiles = list(day_tiles)[1:]
                    first_week = False

                if day_tiles:
                    for tile in day_tiles:
                        if days_collected >= days_ahead:
                            break
                        try:
                            tile.click(force=True)
                            page.wait_for_timeout(700)
                            day_text = get_all_frames_text(page)
                            print(f"  → day {days_collected + 1}: {len(day_text)} chars")
                            all_text += "\n" + day_text
                            days_collected += 1
                        except Exception:
                            pass

                    if days_collected >= days_ahead:
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
                next_btn.click(force=True)
                page.wait_for_timeout(800)

            return all_text
        finally:
            page.close()
            browser.close()

def _parse_raw(page_text: str, studio_id: str, studio_name: str) -> list[dict]:
    """Call Claude Haiku and normalize fields. Location metadata is kept as-is (not resolved to IDs)."""
    today = date.today().isoformat()
    year = date.today().year
    message = _anthropic.messages.create(
        model="claude-haiku-4-5-20251001",
        max_tokens=8192,
        messages=[{
            "role": "user",
            "content": PROMPT.format(today=today, year=year) + "\n\n" + page_text[:12000]
        }]
    )
    raw = message.content[0].text.strip()
    if raw.startswith("```"):
        raw = raw.split("```")[1]
        if raw.startswith("json"):
            raw = raw[4:]
    classes = json.loads(raw)
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


def _fetch_studio(studio: dict) -> tuple[str, list[dict]]:
    """Phase 1 (parallel): fetch pages + parse + normalize. No DB calls."""
    sid = studio["id"]
    name = studio["name"]
    tag = sid[:8]
    db_exclude = studio.get("exclude_keywords") or []
    code_exclude = STUDIO_EXCLUDES.get(name, [])
    exclude = [kw.lower() for kw in (db_exclude or code_exclude)]
    try:
        urls = studio.get("schedule_urls") or []
        all_text = ""
        for url in urls:
            t = fetch_page_text(url, days_ahead=studio.get("days_ahead") or 1)
            print(f"[{tag}] {name}: {url} ({len(t)} chars)")
            all_text += "\n\n" + t
        all_text = all_text.strip()
        if not all_text:
            print(f"[{tag}] {name}: no text, skipping")
            return sid, []
        classes = _parse_raw(all_text, sid, name)
        today_str = date.today().isoformat()
        cutoff = (date.today() + timedelta(days=14)).isoformat()
        classes = [c for c in classes if today_str <= (c.get("date") or "") <= cutoff]
        if exclude:
            classes = [c for c in classes if not any(kw in (c.get("title") or "").lower() for kw in exclude)]
        print(f"[{tag}] {name}: {len(classes)} classes parsed")
        return sid, classes
    except Exception as e:
        import traceback
        print(f"[{tag}] {name}: ERROR {e}")
        traceback.print_exc()
        return sid, []


def _write_studio(studio: dict, classes: list[dict]):
    """Phase 2 (sequential): resolve locations then write classes to DB."""
    sid = studio["id"]
    name = studio["name"]
    tag = sid[:8]
    resolved = []
    for c in classes:
        loc_city = c.pop("_loc_city", None)
        loc_address = c.pop("_loc_address", None)
        if loc_city:
            c["location_id"] = get_or_create_location(sid, name, loc_city, loc_address)
        else:
            if sid not in _default_location_cache:
                _default_location_cache[sid] = get_default_location(sid)
            c["location_id"] = _default_location_cache[sid]
        resolved.append(c)
    replace_future_classes(sid, resolved)
    print(f"[{tag}] {name}: {len(resolved)} classes saved")


def scrape_all(studios: list[dict]):
    # Phase 1: parallel fetch + parse (no DB calls)
    results: dict[str, list[dict]] = {}
    with ThreadPoolExecutor(max_workers=len(studios)) as executor:
        future_to_studio = {executor.submit(_fetch_studio, s): s for s in studios}
        for future in as_completed(future_to_studio):
            sid, classes = future.result()
            results[sid] = classes

    # Phase 2: sequential DB writes in original studio order
    for studio in studios:
        classes = results.get(studio["id"], [])
        if classes:
            _write_studio(studio, classes)
