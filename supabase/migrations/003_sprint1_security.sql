-- Sprint 1 Security: F1 (token hashing) + F2 (rate limiting)
-- F1: rename sync_token/mcp_api_key → *_hash, backfill SHA-256
-- F2: add created_from_ip to setup_codes for IP-based rate limiting

-- F2: track request IP on setup codes
ALTER TABLE public.healthkit_setup_codes
  ADD COLUMN IF NOT EXISTS created_from_ip TEXT;

-- F1: rename columns to signal hashed storage
ALTER TABLE public.healthkit_api_keys
  RENAME COLUMN sync_token  TO sync_token_hash;
ALTER TABLE public.healthkit_api_keys
  RENAME COLUMN mcp_api_key TO mcp_api_key_hash;

-- F1: backfill — hash any existing plaintext rows
-- After this, the old tokens (held on devices) are invalidated;
-- devices will need to re-register. Acceptable for pre-launch test data.
UPDATE public.healthkit_api_keys
SET
  sync_token_hash  = encode(sha256(sync_token_hash::bytea),  'hex'),
  mcp_api_key_hash = encode(sha256(mcp_api_key_hash::bytea), 'hex');

-- Drop old plaintext indexes
DROP INDEX IF EXISTS public.idx_api_keys_sync_token;
DROP INDEX IF EXISTS public.idx_api_keys_mcp_key;

-- Create new indexes on hash columns
CREATE UNIQUE INDEX idx_api_keys_sync_token_hash
  ON public.healthkit_api_keys(sync_token_hash) WHERE NOT revoked;
CREATE UNIQUE INDEX idx_api_keys_mcp_api_key_hash
  ON public.healthkit_api_keys(mcp_api_key_hash) WHERE NOT revoked;
