-- People whose health data this Deployment holds, and the Device keys that let a device write it.
--
-- Health rows key on people.id, a UUID this Deployment generates, never on an auth provider's ID:
-- turning Netlify Identity on later adds a nullable identity_user_id column here and leaves every
-- stored row and every MCP HEALTHKIT_USER_ID valid.

CREATE TABLE people (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  display_name text        NOT NULL DEFAULT '',
  is_owner     boolean     NOT NULL DEFAULT false,
  created_at   timestamptz NOT NULL DEFAULT now()
);

-- At most one Owner: the setup page creates it on first use, and a race between two first
-- requests must not leave two.
CREATE UNIQUE INDEX people_one_owner_idx ON people (is_owner) WHERE is_owner;

-- A Device key is shown once and stored only as its SHA-256 hash. key_prefix is the first
-- characters of the plaintext, kept so the setup page can tell keys apart without revealing them.
CREATE TABLE device_keys (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  person_id    uuid        NOT NULL REFERENCES people(id) ON DELETE CASCADE,
  key_hash     text        NOT NULL UNIQUE,
  key_prefix   text        NOT NULL,
  label        text        NOT NULL DEFAULT '',
  created_at   timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  revoked_at   timestamptz,
  CONSTRAINT device_keys_label_length CHECK (char_length(label) <= 100)
);

CREATE INDEX device_keys_person_idx ON device_keys (person_id, created_at DESC);
