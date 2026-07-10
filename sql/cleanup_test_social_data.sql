-- Removes the test_alice / test_bob seed data. saved_classes for test_bob
-- cascades away automatically when his profile row is deleted (user_id
-- REFERENCES profiles(id) ON DELETE CASCADE), so no separate delete needed
-- for that table.

DELETE FROM follows WHERE follower_id IN (
  SELECT id FROM profiles WHERE username IN ('test_alice', 'test_bob')
) OR following_id IN (
  SELECT id FROM profiles WHERE username IN ('test_alice', 'test_bob')
);

DELETE FROM profiles WHERE username IN ('test_alice', 'test_bob');
