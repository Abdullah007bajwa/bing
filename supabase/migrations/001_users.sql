-- ============================================================
-- Ghost Messaging — Supabase Schema
-- Stores ONLY public keys and user hashes
-- No PII. No messages. No metadata beyond last_seen.
-- ============================================================

-- Enable extensions if needed
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ============================================================
-- USERS TABLE
-- ============================================================

CREATE TABLE IF NOT EXISTS users (
    user_id     TEXT PRIMARY KEY,          -- base58(SHA256(public_key))
    public_key  TEXT NOT NULL,             -- base64 encoded X25519 public key
    created_at  TIMESTAMPTZ DEFAULT now(),
    last_seen   TIMESTAMPTZ DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_users_last_seen
ON users(last_seen);

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Remove policies if they already exist (fixes your error)

DROP POLICY IF EXISTS allow_insert ON users;
DROP POLICY IF EXISTS allow_select_self ON users;
DROP POLICY IF EXISTS allow_update_self ON users;

-- Allow inserts (client registering its key)

CREATE POLICY allow_insert
ON users
FOR INSERT
WITH CHECK (true);

-- Users cannot list all users

CREATE POLICY allow_select_self
ON users
FOR SELECT
USING (false);

-- Updates only allowed through controlled RPC

CREATE POLICY allow_update_self
ON users
FOR UPDATE
USING (false);

-- ============================================================
-- PUBLIC KEY LOOKUP (Metadata-resistant)
-- ============================================================

CREATE OR REPLACE FUNCTION get_public_key_by_hash(
    lookup_hash TEXT
)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    found_key TEXT;
BEGIN
    SELECT public_key
    INTO found_key
    FROM users
    WHERE user_id = lookup_hash
    LIMIT 1;

    RETURN found_key;
END;
$$;

-- ============================================================
-- LAST SEEN UPDATE FUNCTION
-- ============================================================

CREATE OR REPLACE FUNCTION update_last_seen(
    uid TEXT
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    UPDATE users
    SET last_seen = now()
    WHERE user_id = uid;
END;
$$;

-- ============================================================
-- STALE ACCOUNT CLEANUP
-- ============================================================

CREATE OR REPLACE FUNCTION delete_stale_users()
RETURNS VOID
LANGUAGE SQL
AS $$
DELETE FROM users
WHERE last_seen < now() - INTERVAL '90 days';
$$;

-- If pg_cron enabled

-- SELECT cron.schedule(
--   'ghost_delete_stale_users',
--   '0 3 * * *',
--   'SELECT delete_stale_users();'
-- );

-- ============================================================
-- NOTES
-- ============================================================

-- 1. Only public keys stored.
-- 2. Messages NEVER stored in Supabase.
-- 3. user_id = hash(public_key) prevents identity reversal.
-- 4. Public key lookup only possible if exact hash known.
-- 5. Enumeration attacks prevented by RLS + RPC.