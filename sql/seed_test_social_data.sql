-- Seeds fake follow relationships so you can verify Followers / Following /
-- Follow Requests / Find Friends rendering without a second device.
--
-- Prerequisite: create two auth users via Dashboard -> Authentication -> Users
-- -> Add user (Auto Confirm User checked), then paste their UUIDs below.
-- Also set your own username below (whatever you see under your own @handle
-- in the Profile tab).

DO $$
DECLARE
  v_alice_auth_id UUID := '8b31e1c1-f8dc-400d-a55f-a4a25a99ceda'; -- test-alice
  v_bob_auth_id   UUID := '63619380-d95d-4f7f-befe-ba6cf7120481'; -- test-bob
  v_my_username   TEXT := 'annika'; -- <-- your real username, no @

  v_my_id UUID;
BEGIN
  SELECT id INTO v_my_id FROM profiles WHERE username = v_my_username;
  IF v_my_id IS NULL THEN
    RAISE EXCEPTION 'No profile found for username %', v_my_username;
  END IF;
  IF v_alice_auth_id = '00000000-0000-0000-0000-000000000000'
     OR v_bob_auth_id = '00000000-0000-0000-0000-000000000000' THEN
    RAISE EXCEPTION 'Paste real UUIDs for test-alice and test-bob before running this.';
  END IF;

  -- Fake profiles for the two dashboard-created auth users.
  INSERT INTO profiles (id, username) VALUES (v_alice_auth_id, 'test_alice')
    ON CONFLICT (id) DO NOTHING;
  INSERT INTO profiles (id, username) VALUES (v_bob_auth_id, 'test_bob')
    ON CONFLICT (id) DO NOTHING;

  -- Alice sent you a pending follow request -> should appear under "Follow
  -- Requests", with an Accept action you can actually tap through.
  INSERT INTO follows (follower_id, following_id, status)
    VALUES (v_alice_auth_id, v_my_id, 'pending')
    ON CONFLICT (follower_id, following_id) DO UPDATE SET status = 'pending';

  -- You and Bob already follow each other (accepted both directions) ->
  -- Bob should appear in both your "Followers" and "Following" lists/counts.
  INSERT INTO follows (follower_id, following_id, status)
    VALUES (v_bob_auth_id, v_my_id, 'accepted')
    ON CONFLICT (follower_id, following_id) DO UPDATE SET status = 'accepted';
  INSERT INTO follows (follower_id, following_id, status)
    VALUES (v_my_id, v_bob_auth_id, 'accepted')
    ON CONFLICT (follower_id, following_id) DO UPDATE SET status = 'accepted';

  -- A couple of Bob's saved (upcoming) classes, so you can verify they show up
  -- on his profile via the accepted-follower saved_classes RLS policy.
  INSERT INTO saved_classes (user_id, class_id)
    SELECT v_bob_auth_id, id
      FROM classes
     WHERE date >= CURRENT_DATE
     ORDER BY date, start_time
     LIMIT 3
    ON CONFLICT (user_id, class_id) DO NOTHING;

  RAISE NOTICE 'Seeded: test_alice (pending request to you), test_bob (mutual accepted follow + saved classes).';
END $$;

-- To clean up afterward, run:
--
-- DELETE FROM follows WHERE follower_id IN (
--   SELECT id FROM profiles WHERE username IN ('test_alice', 'test_bob')
-- ) OR following_id IN (
--   SELECT id FROM profiles WHERE username IN ('test_alice', 'test_bob')
-- );
-- DELETE FROM profiles WHERE username IN ('test_alice', 'test_bob');
-- -- Then delete the two users via Dashboard -> Authentication -> Users.
