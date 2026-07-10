-- Verifies mark_log_entries_canceled() / the log_entries FK without touching real
-- data: everything runs inside one transaction that's rolled back at the end, pass
-- or fail. Paste this whole file into the Supabase SQL editor and run it.
--
-- PASS looks like two "PASS: ..." NOTICEs and no error. A FAIL raises an exception
-- with a clear message and aborts before anything could commit.

BEGIN;

-- Case 1: canceling an upcoming class should detach (not delete) its log entry,
-- and flag it canceled.
DO $$
DECLARE
  v_studio_id UUID;
  v_profile_id UUID;
  v_class_id UUID := gen_random_uuid();
  v_log_id UUID := gen_random_uuid();
  v_is_canceled BOOLEAN;
  v_source_class_id UUID;
BEGIN
  -- Borrow existing rows as FK references only - never modified.
  SELECT id INTO v_studio_id FROM studios LIMIT 1;
  SELECT id INTO v_profile_id FROM profiles LIMIT 1;
  IF v_studio_id IS NULL OR v_profile_id IS NULL THEN
    RAISE EXCEPTION 'Test requires at least one existing studio and profile row to borrow as FK references.';
  END IF;

  INSERT INTO classes (id, studio_id, title, date, start_time)
  VALUES (v_class_id, v_studio_id, 'TEST - cancellation trigger', CURRENT_DATE + 7, '18:00:00');

  INSERT INTO log_entries (id, user_id, date, title, source_class_id)
  VALUES (v_log_id, v_profile_id, now() + interval '7 days', 'TEST - cancellation trigger', v_class_id);

  -- Simulate the studio canceling the class.
  DELETE FROM classes WHERE id = v_class_id;

  SELECT is_canceled, source_class_id INTO v_is_canceled, v_source_class_id
    FROM log_entries WHERE id = v_log_id;

  IF v_source_class_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (case 1): source_class_id should be NULL after the class is deleted, got %', v_source_class_id;
  END IF;
  IF v_is_canceled IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL (case 1): is_canceled should be TRUE, got %', v_is_canceled;
  END IF;

  RAISE NOTICE 'PASS (case 1): canceling an upcoming class detaches and flags its log entry.';
END $$;

-- Case 2: deleting an already-past class (the daily expiry sweep) must NOT be
-- mistaken for a cancellation - delete_past_log_entries handles that cleanup
-- separately, by date.
DO $$
DECLARE
  v_studio_id UUID;
  v_profile_id UUID;
  v_class_id UUID := gen_random_uuid();
  v_log_id UUID := gen_random_uuid();
  v_is_canceled BOOLEAN;
BEGIN
  SELECT id INTO v_studio_id FROM studios LIMIT 1;
  SELECT id INTO v_profile_id FROM profiles LIMIT 1;

  INSERT INTO classes (id, studio_id, title, date, start_time)
  VALUES (v_class_id, v_studio_id, 'TEST - past-class cleanup', CURRENT_DATE - 1, '18:00:00');

  INSERT INTO log_entries (id, user_id, date, title, source_class_id)
  VALUES (v_log_id, v_profile_id, now() - interval '1 day', 'TEST - past-class cleanup', v_class_id);

  DELETE FROM classes WHERE id = v_class_id;

  SELECT is_canceled INTO v_is_canceled FROM log_entries WHERE id = v_log_id;

  IF v_is_canceled IS TRUE THEN
    RAISE EXCEPTION 'FAIL (case 2): a merely-expired class should not be marked canceled, got TRUE';
  END IF;

  RAISE NOTICE 'PASS (case 2): deleting an already-past class does not mark its log entry canceled.';
END $$;

ROLLBACK;
