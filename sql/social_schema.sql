-- Accounts, following, and shared saved/logged classes.
-- Run this in the Supabase SQL editor after the base schema.sql.

CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  username TEXT UNIQUE NOT NULL,
  display_name TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE follows (
  follower_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  following_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'accepted')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (follower_id, following_id),
  CHECK (follower_id != following_id)
);

CREATE TABLE saved_classes (
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  class_id UUID NOT NULL REFERENCES classes(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  PRIMARY KEY (user_id, class_id)
);

CREATE TABLE log_entries (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  date TIMESTAMPTZ NOT NULL,
  duration_minutes INTEGER,
  title TEXT NOT NULL,
  dance_style TEXT,
  level TEXT,
  instructor TEXT,
  studio TEXT,
  notes TEXT,
  source_class_id UUID REFERENCES classes(id) ON DELETE SET NULL,
  is_canceled BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX ON follows(following_id, status);
CREATE INDEX ON saved_classes(class_id);
CREATE INDEX ON log_entries(user_id);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE follows ENABLE ROW LEVEL SECURITY;
ALTER TABLE saved_classes ENABLE ROW LEVEL SECURITY;
ALTER TABLE log_entries ENABLE ROW LEVEL SECURITY;

-- profiles: usernames are searchable by any signed-in user; only the
-- owner can create/edit their own row.
CREATE POLICY "profiles are readable by authenticated users"
  ON profiles FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "users manage their own profile"
  ON profiles FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = id);

CREATE POLICY "users update their own profile"
  ON profiles FOR UPDATE
  TO authenticated
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- follows: accepted edges are visible to everyone (follower/following
-- counts, lists); pending edges are only visible to the two parties.
CREATE POLICY "accepted follows are public, pending follows are private"
  ON follows FOR SELECT
  TO authenticated
  USING (status = 'accepted' OR auth.uid() IN (follower_id, following_id));

CREATE POLICY "users send follow requests as themselves"
  ON follows FOR INSERT
  TO authenticated
  WITH CHECK (auth.uid() = follower_id);

CREATE POLICY "only the target can accept a follow request"
  ON follows FOR UPDATE
  TO authenticated
  USING (auth.uid() = following_id)
  WITH CHECK (auth.uid() = following_id);

CREATE POLICY "either party can remove a follow edge"
  ON follows FOR DELETE
  TO authenticated
  USING (auth.uid() IN (follower_id, following_id));

-- saved_classes / log_entries: visible to the owner, or to an
-- accepted follower of the owner. Only the owner can write.
CREATE POLICY "saved classes visible to owner and accepted followers"
  ON saved_classes FOR SELECT
  TO authenticated
  USING (
    auth.uid() = user_id
    OR EXISTS (
      SELECT 1 FROM follows
      WHERE follower_id = auth.uid()
        AND following_id = saved_classes.user_id
        AND status = 'accepted'
    )
  );

CREATE POLICY "users manage their own saved classes"
  ON saved_classes FOR ALL
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "log entries visible to owner and accepted followers"
  ON log_entries FOR SELECT
  TO authenticated
  USING (
    auth.uid() = user_id
    OR EXISTS (
      SELECT 1 FROM follows
      WHERE follower_id = auth.uid()
        AND following_id = log_entries.user_id
        AND status = 'accepted'
    )
  );

CREATE POLICY "users manage their own log entries"
  ON log_entries FOR ALL
  TO authenticated
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Profile avatars: stored in the "avatars" storage bucket at
-- "{user_id}/avatar.jpg"; profiles.avatar_url points at the public URL.
ALTER TABLE profiles ADD COLUMN avatar_url TEXT;

INSERT INTO storage.buckets (id, name, public)
VALUES ('avatars', 'avatars', true)
ON CONFLICT (id) DO NOTHING;

CREATE POLICY "avatar images are publicly accessible"
  ON storage.objects FOR SELECT
  USING (bucket_id = 'avatars');

CREATE POLICY "users upload their own avatar"
  ON storage.objects FOR INSERT
  TO authenticated
  WITH CHECK (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "users update their own avatar"
  ON storage.objects FOR UPDATE
  TO authenticated
  USING (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::text);

CREATE POLICY "users delete their own avatar"
  ON storage.objects FOR DELETE
  TO authenticated
  USING (bucket_id = 'avatars' AND (storage.foldername(name))[1] = auth.uid()::text);

-- When a class is deleted while still upcoming (a genuine cancellation, not the
-- daily expiry sweep — that's handled separately, precisely, by date in
-- delete_past_log_entries), mark any log_entries pointing at it as canceled
-- before the FK's ON DELETE SET NULL detaches them. SECURITY DEFINER: this runs
-- as part of the scraper's own DELETE FROM classes (not a signed-in user's
-- session), so it must bypass log_entries' owner-only RLS to write the flag.
CREATE OR REPLACE FUNCTION mark_log_entries_canceled()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.date >= CURRENT_DATE THEN
    UPDATE log_entries
    SET is_canceled = TRUE
    WHERE source_class_id = OLD.id;
  END IF;
  RETURN OLD;
END;
$$;

DROP TRIGGER IF EXISTS classes_before_delete_mark_canceled ON classes;
CREATE TRIGGER classes_before_delete_mark_canceled
  BEFORE DELETE ON classes
  FOR EACH ROW
  EXECUTE FUNCTION mark_log_entries_canceled();
