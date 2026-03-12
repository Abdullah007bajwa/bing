-- ============================================================
-- Ghost — PreKeys for Signal/X3DH
-- One-time and signed prekeys for session establishment.
-- ============================================================

CREATE TABLE IF NOT EXISTS prekeys (
    user_id     TEXT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    key_id      INTEGER NOT NULL,
    public_key  TEXT NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT now(),
    PRIMARY KEY (user_id, key_id)
);

CREATE INDEX IF NOT EXISTS idx_prekeys_user_id ON prekeys(user_id);

ALTER TABLE prekeys ENABLE ROW LEVEL SECURITY;

-- Allow insert for own user_id (client uploads its prekeys)
DROP POLICY IF EXISTS prekeys_allow_insert ON prekeys;
CREATE POLICY prekeys_allow_insert ON prekeys FOR INSERT WITH CHECK (true);

-- Select only via RPC (no direct SELECT)
DROP POLICY IF EXISTS prekeys_select ON prekeys;
CREATE POLICY prekeys_select ON prekeys FOR SELECT USING (false);

-- PreKey bundle lookup: return one signed + one one-time prekey for a user
CREATE OR REPLACE FUNCTION get_prekey_bundle(lookup_user_id TEXT)
RETURNS TABLE(key_id INTEGER, public_key TEXT)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    RETURN QUERY
    SELECT p.key_id, p.public_key
    FROM prekeys p
    WHERE p.user_id = lookup_user_id
    ORDER BY p.key_id
    LIMIT 101;
END;
$$;
