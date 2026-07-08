# Studio Hop

A Bay Area dance-class aggregator. A Python scraper collects upcoming class schedules
from local dance studios into a Supabase (Postgres) database, and a SwiftUI iOS app
("Studio Hop") lets you browse, filter, save, and log classes.

## Architecture

```
studio websites ──▶ scraper (Python + Playwright + Claude Haiku) ──▶ Supabase Postgres ──▶ iOS app (SwiftUI)
```

- **`schema.sql`** — database schema: `studios` → `locations` → `classes`.
- **`scraper/`** — daily scrape job. Fetches each studio's schedule page and extracts
  structured classes. Handles several booking platforms with dedicated fast paths
  (Acuity/`.as.me`, Wix Bookings API, Momence/Calendly via Linktree, Rae Studios' iframe
  widget, and EDS via its GraphQL API); generic pages are rendered with Playwright and
  parsed by Claude Haiku, then normalized against fixed style/level vocabularies.
- **`ios/`** — the SwiftUI app (iOS 17+). Reads directly from Supabase with the anon key.
  "Saved" hearts and the on-device "class log" live in `UserDefaults`, not the shared DB.

## Scraper

### Setup

```bash
cd scraper
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
playwright install chromium
```

### Environment variables

Set these (e.g. in a `scraper/.env` file — `.env` is gitignored):

| Variable | Purpose |
| --- | --- |
| `SUPABASE_URL` | Your Supabase project URL |
| `SUPABASE_KEY` | Supabase key. Use the **service role** key for the scraper (it writes). |
| `ANTHROPIC_API_KEY` | Claude API key, used for the Haiku parse fallback |
| `SCRAPE_CONCURRENCY` | *(optional)* Max studios fetched in parallel. Each spawns a Chromium browser (~0.5 GB + several processes), so keep this low on small machines. Defaults to 4; the CI workflow sets 3. |

### One-time database setup

Apply the schema and the atomic-write function to your Supabase project (Dashboard →
SQL Editor → paste and run each):

1. `schema.sql` — tables and indexes.
2. `sql/replace_future_classes.sql` — the Postgres function the scraper calls to prune +
   upsert a studio's classes **in a single transaction**. Without it deployed, the
   scraper's writes will fail (the `replace_future_classes` RPC won't exist). Re-run this
   file whenever the `classes` columns change, since the function lists them explicitly.

### Run

```bash
cd scraper
python main.py
```

`main.py` deletes past classes, loads the studios from the DB, then scrapes each one in
its own timeout-guarded subprocess (bounded concurrency), writing results as they finish.
It prints a per-studio coverage line and an end-of-run summary (`complete / partial /
failed`) so silent gaps are visible.

**Data-safety model.** Each studio scrape reports a `covered_through` date — the furthest
day it could actually reach:

- **Failed / untrustworthy** (exception, no page text, timeout, empty parse) → the
  studio's existing rows are **left untouched**. A broken scrape never deletes good data.
- **Partial** (paginated only part of the 14-day window) → rows are refreshed **only up
  to the furthest date reached**; later-dated rows from a previous, more-complete run are
  preserved.
- **Complete** (reached the full window) → the whole window is refreshed.

This means a studio that genuinely has zero classes is treated as a failed fetch (kept as
stale) rather than being cleared — an intentional bias toward never destroying data,
since a real dance studio almost never has a truly empty two-week schedule.

### Tests

The pure normalization helpers are unit-tested with the standard library (no pytest or
third-party deps required — heavy imports are stubbed):

```bash
cd scraper
python3 -m unittest test_normalizers
```

Requires Python 3.9+ (the scraper uses `list[dict]` / `X | None` type hints).

### Scheduling

A daily scrape runs via GitHub Actions — see `.github/workflows/scrape.yml`. It needs the
three environment variables above configured as repository secrets
(Settings → Secrets and variables → Actions):
`SUPABASE_URL`, `SUPABASE_KEY`, `ANTHROPIC_API_KEY`.

## iOS app

Built with [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `ios/project.yml`.

```bash
cd ios
xcodegen generate
open Dance.xcodeproj
```

Supabase connection lives in `ios/Dance/SupabaseClient.swift` (project URL + anon key).

> **Note on the shipped anon key:** the app embeds the Supabase *anon* key, which is
> normal — but only safe if Row Level Security (RLS) is enabled and the `anon` role has
> **read-only** access to `classes`, `studios`, and `locations`. Confirm RLS policies in
> the Supabase dashboard; otherwise anyone who extracts the key from the app binary could
> modify or delete data.

### Keeping styles in sync

The scraper's canonical dance-style list (`_VALID_STYLES` in `scraper/scraper.py`) and the
app's `styleColor` mapping (`ios/Dance/Models.swift`) must be kept in sync — a style the
scraper emits but the app doesn't recognize renders with the default color.
