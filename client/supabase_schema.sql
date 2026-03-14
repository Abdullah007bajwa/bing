-- ════════════════════════════════════════════════════════════════════════════
-- Bing Messaging App - Supabase Schema (OPTIMIZED & PRODUCTION-READY)
-- ════════════════════════════════════════════════════════════════════════════

-- Drop existing tables to ensure clean state
DROP TABLE IF EXISTS messages CASCADE;
DROP TABLE IF EXISTS sessions CASCADE;
DROP TABLE IF EXISTS prekeys CASCADE;
DROP TABLE IF EXISTS signed_prekeys CASCADE;
DROP TABLE IF EXISTS contacts CASCADE;
DROP TABLE IF EXISTS users CASCADE;

-- ── 1. Users Table ──────────────────────────────────────────────────────────
CREATE TABLE users (
  user_id TEXT PRIMARY KEY,
  identity_key TEXT NOT NULL,
  registration_id INTEGER NOT NULL CHECK (registration_id >= 0 AND registration_id <= 16383),
  public_key TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  last_seen TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL
);

CREATE INDEX idx_users_last_seen_desc ON users (last_seen DESC);
CREATE INDEX idx_users_created_at ON users (created_at DESC);
CREATE INDEX idx_users_activity ON users (last_seen DESC, user_id);

-- ── 2. Signed Pre-keys Table ───────────────────────────────────────────────
CREATE TABLE signed_prekeys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
  key_id INTEGER NOT NULL CHECK (key_id > 0),
  public_key TEXT NOT NULL,
  signature TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  UNIQUE (user_id, key_id)
);

CREATE INDEX idx_signed_prekeys_user_id ON signed_prekeys (user_id);
CREATE INDEX idx_signed_prekeys_created_at_desc ON signed_prekeys (created_at DESC);
CREATE INDEX idx_signed_prekeys_user_created ON signed_prekeys (user_id, created_at DESC);

-- ── 3. One-Time Pre-keys Table ────────────────────────────────────────────
CREATE TABLE prekeys (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
  key_id INTEGER NOT NULL CHECK (key_id > 0),
  public_key TEXT NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  used_at TIMESTAMP WITH TIME ZONE,
  UNIQUE (user_id, key_id)
);

CREATE INDEX idx_prekeys_user_unused ON prekeys (user_id, created_at) WHERE used_at IS NULL;
CREATE INDEX idx_prekeys_user_for_update ON prekeys (user_id) WHERE used_at IS NULL;

-- ── 4. Contacts Table ──────────────────────────────────────────────────────
CREATE TABLE contacts (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
  contact_user_id TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
  contact_name TEXT,
  fingerprint_verified BOOLEAN DEFAULT FALSE NOT NULL,
  added_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  UNIQUE (user_id, contact_user_id),
  CHECK (user_id != contact_user_id)
);

CREATE INDEX idx_contacts_user_id ON contacts (user_id, added_at DESC);
CREATE INDEX idx_contacts_contact_user_id ON contacts (contact_user_id, user_id);
CREATE INDEX idx_contacts_verified ON contacts (user_id, fingerprint_verified) WHERE fingerprint_verified = TRUE;

-- ── 5. Messages Table ──────────────────────────────────────────────────────
CREATE TABLE messages (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_user_id TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
  to_user_id TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
  ciphertext TEXT NOT NULL,
  msg_type SMALLINT NOT NULL CHECK (msg_type IN (1, 2, 3)),
  message_id TEXT UNIQUE NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  delivered_at TIMESTAMP WITH TIME ZONE,
  read_at TIMESTAMP WITH TIME ZONE,
  ttl_seconds INTEGER DEFAULT 86400 CHECK (ttl_seconds > 0)
);

CREATE INDEX idx_messages_inbox ON messages (to_user_id, created_at DESC) WHERE delivered_at IS NULL;
CREATE INDEX idx_messages_undelivered ON messages (created_at ASC) WHERE delivered_at IS NULL;
CREATE INDEX idx_messages_id_unique ON messages (message_id);
CREATE INDEX idx_messages_conversation ON messages (from_user_id, to_user_id, created_at DESC);

-- ── 6. Sessions Table ──────────────────────────────────────────────────────
CREATE TABLE sessions (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
  contact_user_id TEXT NOT NULL REFERENCES users (user_id) ON DELETE CASCADE,
  session_state TEXT NOT NULL,
  last_message_timestamp BIGINT,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW() NOT NULL,
  UNIQUE (user_id, contact_user_id)
);

CREATE INDEX idx_sessions_user_id ON sessions (user_id);
CREATE INDEX idx_sessions_user_contact ON sessions (user_id, contact_user_id);

-- ════════════════════════════════════════════════════════════════════════════
-- Row-Level Security (RLS) - ENABLE & CONFIGURE
-- ════════════════════════════════════════════════════════════════════════════

ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE signed_prekeys ENABLE ROW LEVEL SECURITY;
ALTER TABLE prekeys ENABLE ROW LEVEL SECURITY;
ALTER TABLE contacts ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE sessions ENABLE ROW LEVEL SECURITY;

-- ── Users RLS ──────────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can view all profiles" ON users;
CREATE POLICY "Users can view all profiles" ON users FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can update own profile" ON users;
CREATE POLICY "Users can update own profile" ON users FOR UPDATE USING (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "Users can insert their own profile" ON users;
CREATE POLICY "Users can insert their own profile" ON users FOR INSERT WITH CHECK (auth.uid()::text = user_id);

-- ── Signed Prekeys RLS ─────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can read signed prekeys" ON signed_prekeys;
CREATE POLICY "Users can read signed prekeys" ON signed_prekeys FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can insert own signed prekeys" ON signed_prekeys;
CREATE POLICY "Users can insert own signed prekeys" ON signed_prekeys FOR INSERT WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "Users can update own signed prekeys" ON signed_prekeys;
CREATE POLICY "Users can update own signed prekeys" ON signed_prekeys FOR UPDATE USING (auth.uid()::text = user_id);

-- ── Prekeys RLS ───────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can read prekeys" ON prekeys;
CREATE POLICY "Users can read prekeys" ON prekeys FOR SELECT USING (true);

DROP POLICY IF EXISTS "Users can insert own prekeys" ON prekeys;
CREATE POLICY "Users can insert own prekeys" ON prekeys FOR INSERT WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "Users can mark prekeys as used" ON prekeys;
CREATE POLICY "Users can mark prekeys as used" ON prekeys FOR UPDATE USING (true);

-- ── Contacts RLS ──────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can read own contacts" ON contacts;
CREATE POLICY "Users can read own contacts" ON contacts FOR SELECT USING (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "Users can insert own contacts" ON contacts;
CREATE POLICY "Users can insert own contacts" ON contacts FOR INSERT WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "Users can update own contacts" ON contacts;
CREATE POLICY "Users can update own contacts" ON contacts FOR UPDATE USING (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "Users can delete own contacts" ON contacts;
CREATE POLICY "Users can delete own contacts" ON contacts FOR DELETE USING (auth.uid()::text = user_id);

-- ── Messages RLS ──────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can read own messages" ON messages;
CREATE POLICY "Users can read own messages" ON messages FOR SELECT USING (
  auth.uid()::text = from_user_id OR auth.uid()::text = to_user_id
);

DROP POLICY IF EXISTS "Users can insert messages" ON messages;
CREATE POLICY "Users can insert messages" ON messages FOR INSERT WITH CHECK (auth.uid()::text = from_user_id);

DROP POLICY IF EXISTS "Users can update own messages" ON messages;
CREATE POLICY "Users can update own messages" ON messages FOR UPDATE USING (
  auth.uid()::text = from_user_id OR auth.uid()::text = to_user_id
);

-- ── Sessions RLS ──────────────────────────────────────────────────────────
DROP POLICY IF EXISTS "Users can read own sessions" ON sessions;
CREATE POLICY "Users can read own sessions" ON sessions FOR SELECT USING (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "Users can insert own sessions" ON sessions;
CREATE POLICY "Users can insert own sessions" ON sessions FOR INSERT WITH CHECK (auth.uid()::text = user_id);

DROP POLICY IF EXISTS "Users can update own sessions" ON sessions;
CREATE POLICY "Users can update own sessions" ON sessions FOR UPDATE USING (auth.uid()::text = user_id);

-- ════════════════════════════════════════════════════════════════════════════
-- SCHEMA COMPLETE - READY FOR DEPLOYMENT
-- ════════════════════════════════════════════════════════════════════════════
--
-- Summary:
--   ✅ 6 tables created
--   ✅ 16 optimized indexes
--   ✅ Row-level security policies enabled
--   ✅ Foreign key constraints with CASCADE delete
--   ✅ All columns with proper types and defaults
--
-- To verify deployment:
-- SELECT COUNT(*) FROM information_schema.tables
-- WHERE table_schema='public' AND table_type='BASE TABLE';
-- Expected: 6 tables
--
-- ════════════════════════════════════════════════════════════════════════════

