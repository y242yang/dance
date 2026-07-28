-- Verifies deleting a class row cascades to remove saved_classes/log_entries
-- referencing it, with no detached/canceled state left behind anywhere. Replaces
-- the old soft-cancel trigger test (removed 2026-07-27 along with the feature it
-- tested) now that both are plain FK ON DELETE CASCADE.
--
-- Everything runs inside one transaction that's rolled back at the end, pass or
-- fail. Paste this whole file into the Supabase SQL editor and run it.
--
-- PASS looks like a "PASS: ..." NOTICE and no error. A FAIL raises an exception
-- with a clear message and aborts before anything could commit.

BEGIN;

DO $$
DECLARE
  v_studio_id UUID;
  v_profile_id UUID;
  v_class_id UUID := gen_random_uuid();
  v_log_id UUID := gen_random_uuid();
BEGIN
  -- Borrow existing rows as FK references only - never modified.
  SELECT id INTO v_studio_id FROM studios LIMIT 1;
  SELECT id INTO v_profile_id FROM profiles LIMIT 1;
  IF v_studio_id IS NULL OR v_profile_id IS NULL THEN
    RAISE EXCEPTION 'Test requires at least one existing studio and profile row to borrow as FK references.';
  END IF;

  INSERT INTO classes (id, studio_id, title, date, start_time)
  VALUES (v_class_id, v_studio_id, 'TEST - cascade delete', CURRENT_DATE + 7, '18:00:00');

  INSERT INTO saved_classes (user_id, class_id)
  VALUES (v_profile_id, v_class_id);

  INSERT INTO log_entries (id, user_id, date, title, source_class_id)
  VALUES (v_log_id, v_profile_id, now() + interval '7 days', 'TEST - cascade delete', v_class_id);

  -- Simulate the scraper dropping this class (a scraper miss or a genuine
  -- studio cancellation - replace_future_classes deletes either way now).
  DELETE FROM classes WHERE id = v_class_id;

  IF EXISTS (SELECT 1 FROM saved_classes WHERE class_id = v_class_id) THEN
    RAISE EXCEPTION 'FAIL: saved_classes row should have been cascade-deleted with its class.';
  END IF;

  IF EXISTS (SELECT 1 FROM log_entries WHERE id = v_log_id) THEN
    RAISE EXCEPTION 'FAIL: log_entries row should have been cascade-deleted with its class, found one still present.';
  END IF;

  RAISE NOTICE 'PASS: deleting a class cascades to remove both its saved_classes and log_entries references.';
END $$;

ROLLBACK;
