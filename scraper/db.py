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
    """Remove classes whose date has already passed. Safe for clients: the app's
    Saved view already filters to date >= today, and "My Class Log" is stored
    locally on-device and doesn't reference this table."""
    from datetime import date
    today = date.today().isoformat()
    get_client().table("classes").delete().lt("date", today).execute()

def replace_future_classes(studio_id: str, classes: list[dict], covered_through: str):
    """Upsert by (deterministic) id so unchanged classes keep the same id across
    scrapes — clients that reference a class by id (e.g. saved/hearted classes)
    aren't invalidated every time this runs. Classes no longer present (canceled
    or removed) are deleted.

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
