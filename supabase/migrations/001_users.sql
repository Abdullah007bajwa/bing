-- ============================================================
-- Ghost Messaging — Supabase Schema
-- Purpose: Store ONLY public keys + user IDs. Zero PII.
-- ============================================================

-- Public key registry — NO names, emails, phone numbers
CREATE TABLE IF NOT EXISTS users (
    user_id     TEXT PRIMARY KEY,           -- base58(SHA-256(public_key))
    public_key  TEXT NOT NULL,              -- base64-encoded X25519 identity public key
    created_at  TIMESTAMPTZ DEFAULT now(),
    last_seen   TIMESTAMPTZ DEFAULT now()   -- updated on relay connection; no IP stored
);

-- ── Row-Level Security ─────────────────────────────────────────────────────
ALTER TABLE users ENABLE ROW LEVEL SECURITY;

-- Anyone can read public keys (needed for contact lookup by ID)
CREATE POLICY "public_key_read" ON users
    FOR SELECT USING (true);

-- Users can only insert their own record (JWT sub must match user_id)
CREATE POLICY "self_insert_only" ON users
    FOR INSERT WITH CHECK (
        user_id = (current_setting('request.jwt.claims', true)::json->>'sub')
    );

-- Users can only update their own last_seen
CREATE POLICY "self_update_only" ON users
    FOR UPDATE USING (
        user_id = (current_setting('request.jwt.claims', true)::json->>'sub')
    );

-- Users can delete their own record (account wipe)
CREATE POLICY "self_delete_only" ON users
    FOR DELETE USING (
        user_id = (current_setting('request.jwt.claims', true)::json->>'sub')
    );

-- ── Auto-delete stale accounts (90 days inactive) ─────────────────────────
CREATE OR REPLACE FUNCTION delete_stale_users()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
AS $$
    DELETE FROM users
    WHERE last_seen < now() - INTERVAL '90 days';
$$;

-- Schedule via pg_cron (enable pg_cron extension in Supabase dashboard):
-- SELECT cron.schedule('delete-stale-users', '0 2 * * *', 'SELECT delete_stale_users()');

-- ── Indexes ────────────────────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_users_last_seen ON users(last_seen);

-- ============================================================
-- NOTES:
-- 1. No message content is ever stored here. Server is a blind relay.
-- 2. user_id is a hash — not reversible to identity.
-- 3. Public key lookup is needed for contact-add-by-ID flow only.
-- 4. No server-side group membership table — groups are client-managed.
-- ============================================================
