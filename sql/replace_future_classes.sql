-- Atomic replacement of a studio's future classes within a covered date window.
--
-- Deploy this in the Supabase SQL editor (Dashboard -> SQL Editor -> run). The
-- scraper calls it via PostgREST RPC (db.replace_future_classes), replacing the old
-- two-step DELETE-then-UPSERT. A plpgsql function runs in a single implicit
-- transaction, so a crash mid-write can no longer leave a studio's rows deleted but
-- not re-inserted (which would blank the studio until the next run).
--
-- Requires sql/social_schema.sql's "is_canceled on classes" migration to have been
-- run first (classes.is_canceled must exist).
--
-- Semantics:
--   * Rows in [p_today, p_covered_through] missing from this scrape are handled two
--     ways:
--       - If nobody has saved_classes/heart on the row: hard delete, same as before.
--       - If someone has it saved: soft-cancel instead (set is_canceled = true, keep
--         the row). A scrape miss (or a real cancellation) then shows as "unconfirmed"
--         in a saved list rather than silently vanishing and cascade-deleting the
--         heart. See sql/social_schema.sql for why saved_classes needed this and
--         log_entries already had it via its own is_canceled + ON DELETE SET NULL.
--   * Upsert the provided rows by id (stable ids keep saved/hearted classes valid),
--     resetting is_canceled = false -- if a class is present in a fresh scrape, it is
--     by definition not canceled, even if a prior run had flagged it.
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

    -- Soft-cancel: missing from this scrape, but still saved by someone. Keep the
    -- row (and the heart) so the daily scrape can never silently destroy a user's
    -- save -- only an explicit unsave, or the row aging into the past via
    -- delete_past_classes, removes it after this.
    update classes c
       set is_canceled = true
     where c.studio_id = p_studio_id
       and c.date >= p_today
       and c.date <= p_covered_through
       and (v_ids is null or c.id <> all(v_ids))
       and exists (select 1 from saved_classes sc where sc.class_id = c.id);

    -- Hard delete: missing from this scrape, and nobody has it saved -- safe to prune.
    -- (v_ids IS NULL -> empty scrape -> delete the whole covered range for this
    -- studio, minus whatever just got soft-canceled above.)
    delete from classes c
     where c.studio_id = p_studio_id
       and c.date >= p_today
       and c.date <= p_covered_through
       and (v_ids is null or c.id <> all(v_ids))
       and not exists (select 1 from saved_classes sc where sc.class_id = c.id);

    -- Upsert the current classes.
    insert into classes (
        id, studio_id, location_id, title, dance_style, instructor, level,
        date, start_time, duration_minutes, description, is_canceled
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
        elem->>'description',
        false
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
        description      = excluded.description,
        is_canceled      = false;
end;
$$;
