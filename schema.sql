CREATE TABLE studios (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name TEXT NOT NULL,
  schedule_urls TEXT[] NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE locations (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id UUID NOT NULL REFERENCES studios(id) ON DELETE CASCADE,
  name TEXT,
  address TEXT,
  city TEXT
);

CREATE TABLE classes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  studio_id UUID NOT NULL REFERENCES studios(id) ON DELETE CASCADE,
  location_id UUID REFERENCES locations(id),
  title TEXT NOT NULL,
  dance_style TEXT,
  instructor TEXT,
  level TEXT CHECK (level IN ('beginner', 'intermediate', 'advanced', 'all_levels', 'open')),
  date DATE NOT NULL,
  start_time TIME NOT NULL,
  duration_minutes INTEGER,
  description TEXT,
  is_workshop BOOLEAN DEFAULT FALSE,
  scraped_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX ON classes(date);
CREATE INDEX ON classes(studio_id);
CREATE INDEX ON classes(dance_style);
CREATE INDEX ON classes(instructor);
CREATE INDEX ON classes(level);
