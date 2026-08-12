import os
from typing import Optional
from supabase import create_client, Client
from dotenv import load_dotenv

load_dotenv()

_client: Client = None

def get_client() -> Client:
    global _client
    if _client is None:
        _client = create_client(os.environ["SUPABASE_URL"], os.environ["SUPABASE_KEY"])
    return _client

def get_studios():
    return get_client().table("studios").select("*").execute().data

def get_or_create_location(studio_id: str, studio_name: str, city: str, address: str = None) -> str:
    db = get_client()
    name = f"{studio_name} - {city}"
    existing = db.table("locations").select("id").eq("studio_id", studio_id).eq("name", name).execute().data
    if existing:
        return existing[0]["id"]
    result = db.table("locations").insert({
        "studio_id": studio_id,
        "name": name,
        "address": address,
        "city": city,
    }).execute()
    return result.data[0]["id"]

def get_default_location(studio_id: str) -> Optional[str]:
    """Return the first pre-seeded location id for a studio, or None."""
    result = get_client().table("locations").select("id") \
        .eq("studio_id", studio_id).limit(1).execute().data
    return result[0]["id"] if result else None

def delete_past_classes():
    """Remove classes whose date has already passed. saved_classes rows for these
    classes cascade-delete automatically (FK ON DELETE CASCADE); class-sourced
    log_entries rows do too. Manually-typed log entries aren't tied to a class row,
    so they're handled separately by delete_past_log_entries()."""
    from datetime import date
    today = date.today().isoformat()
    get_client().table("classes").delete().lt("date", today).execute()

def delete_past_log_entries():
    """Remove log entries whose date has already passed. Covers both class-sourced
    entries (belt-and-suspenders alongside the FK cascade in delete_past_classes)
    and manually-typed entries, which have no classes row to cascade from."""
    from datetime import date
    today = date.today().isoformat()
    get_client().table("log_entries").delete().lt("date", today).execute()

# PostgREST caps an unbounded select at 1000 rows. The whole 10-day window across every
# studio is a few hundred today, but an implicit cap would silently under-report the
# health check that exists to catch under-reporting, so it's explicit and checked.
_MAX_WINDOW_ROWS = 20000


def fetch_window_class_ids(studio_id: str, from_date: str, to_date: str) -> set:
    """Ids of the classes actually stored for a studio in [from_date, to_date].

    Read back immediately after a write so the run can prove the write landed, rather
    than trusting that the RPC returning without an exception means the rows are there.
    """
    rows = get_client().table("classes").select("id") \
        .eq("studio_id", studio_id).gte("date", from_date).lte("date", to_date) \
        .limit(_MAX_WINDOW_ROWS).execute().data
    return {r["id"] for r in rows}


def fetch_window_rows(from_date: str, to_date: str) -> list[dict]:
    """(studio_id, date) for every stored class in the window, in one query, for the
    end-of-run health report. One query rather than per-studio so the report costs the
    same whether there are 12 studios or 50."""
    rows = get_client().table("classes").select("studio_id,date") \
        .gte("date", from_date).lte("date", to_date) \
        .limit(_MAX_WINDOW_ROWS).execute().data
    if len(rows) >= _MAX_WINDOW_ROWS:
        print(f"  → WARNING: window read hit the {_MAX_WINDOW_ROWS}-row cap; the health "
              f"report below is incomplete. Raise _MAX_WINDOW_ROWS in db.py.")
    return rows


def replace_future_classes(studio_id: str, classes: list[dict], covered_through: str):
    """Upsert by (deterministic) id so unchanged classes keep the same id across
    scrapes — clients that reference a class by id (e.g. saved/hearted classes)
    aren't invalidated every time this runs. Classes no longer present in the
    scrape are hard deleted unconditionally, including ones a user has saved or
    committed to — saved_classes/log_entries clean up their own reference via FK
    cascade. See sql/replace_future_classes.sql for the exact logic.

    `covered_through` (YYYY-MM-DD) is the furthest date this scrape actually reached.
    Deletion is scoped to [today, covered_through], so a run that only paginated part
    way through the window can refresh the days it saw WITHOUT erasing later-dated rows
    from a previous, more-complete run. Callers must not pass classes dated beyond
    covered_through.

    The prune + upsert happen atomically inside a Postgres function (see
    sql/replace_future_classes.sql — deploy it once in the Supabase SQL editor). Doing
    both in one transaction means a crash mid-write can't leave a studio's rows deleted
    but not re-inserted. `today` is passed in so the DB's timezone is irrelevant.
    """
    from datetime import date
    get_client().rpc("replace_future_classes", {
        "p_studio_id": studio_id,
        "p_today": date.today().isoformat(),
        "p_covered_through": covered_through,
        "p_classes": classes,
    }).execute()
