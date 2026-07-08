-- Atomic replacement of a studio's future classes within a covered date window.
--
-- Deploy this once in the Supabase SQL editor (Dashboard → SQL Editor → run). The
-- scraper calls it via PostgREST RPC (db.replace_future_classes), replacing the old
-- two-step DELETE-then-UPSERT. A plpgsql function runs in a single implicit
-- transaction, so a crash mid-write can no longer leave a studio's rows deleted but
-- not re-inserted (which would blank the studio until the next run).
--
-- Semantics (must match the previous Python implementation):
--   * Delete this studio's rows in [p_today, p_covered_through] EXCEPT those being
--     re-upserted (identified by id). Scoping to the covered window means a partial
--     scrape never erases later-dated rows from a prior, more-complete run.
--   * Upsert the provided rows by id (stable ids keep saved/hearted classes valid).
--   * p_today is supplied by the caller so the DB's timezone is irrelevant.

create or replace function replace_future_classes(
    p_studio_id uuid,
    p_today date,
    p_covered_through date,
    p_classes jsonb
) returns void
language plpgsql
as $$
declare
    v_ids uuid[];
begin
    -- ids of the rows we're about to (re)insert; NULL if p_classes is empty.
    select array_agg((elem->>'id')::uuid)
      into v_ids
      from jsonb_array_elements(coalesce(p_classes, '[]'::jsonb)) elem;

    -- Prune stale future rows within the covered window, keeping the ones we re-upsert.
    -- (v_ids IS NULL → empty scrape → delete the whole covered range for this studio.)
    delete from classes c
     where c.studio_id = p_studio_id
       and c.date >= p_today
       and c.date <= p_covered_through
       and (v_ids is null or c.id <> all(v_ids));

    -- Upsert the current classes.
    insert into classes (
        id, studio_id, location_id, title, dance_style, instructor, level,
        date, start_time, duration_minutes, description
    )
    select
        (elem->>'id')::uuid,
        (elem->>'studio_id')::uuid,
        (elem->>'location_id')::uuid,
        elem->>'title',
        elem->>'dance_style',
        elem->>'instructor',
        elem->>'level',
        (elem->>'date')::date,
        (elem->>'start_time')::time,
        (elem->>'duration_minutes')::int,
        elem->>'description'
      from jsonb_array_elements(coalesce(p_classes, '[]'::jsonb)) elem
    on conflict (id) do update set
        studio_id        = excluded.studio_id,
        location_id      = excluded.location_id,
        title            = excluded.title,
        dance_style      = excluded.dance_style,
        instructor       = excluded.instructor,
        level            = excluded.level,
        date             = excluded.date,
        start_time       = excluded.start_time,
        duration_minutes = excluded.duration_minutes,
        description      = excluded.description;
end;
$$;
