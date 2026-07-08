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

def replace_future_classes(studio_id: str, classes: list[dict]):
    """Upsert by (deterministic) id so unchanged classes keep the same id across
    scrapes — clients that reference a class by id (e.g. saved/hearted classes)
    aren't invalidated every time this runs. Classes no longer present (canceled
    or removed) are deleted."""
    db = get_client()
    from datetime import date
    today = date.today().isoformat()
    new_ids = [c["id"] for c in classes]
    q = db.table("classes").delete().eq("studio_id", studio_id).gte("date", today)
    if new_ids:
        q = q.not_.in_("id", new_ids)
    q.execute()
    if classes:
        db.table("classes").upsert(classes, on_conflict="id").execute()
