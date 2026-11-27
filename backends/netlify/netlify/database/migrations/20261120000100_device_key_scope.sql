-- A Device key either writes (a phone, accepted by /api/ingest) or reads (for a reader such as a
-- dashboard). Separate scopes keep a reader's key, which may sit in a browser or a config file,
-- from writing data, and a phone's key from reading it. Every key issued before this migration was
-- a phone's, so existing rows become 'write'.
-- IF NOT EXISTS: some Deployments of a fork already have this column, with the same definition.

ALTER TABLE device_keys
  ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT 'write'
  CONSTRAINT device_keys_scope_valid CHECK (scope IN ('write', 'read'));
