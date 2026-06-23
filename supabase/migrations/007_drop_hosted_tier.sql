-- Drop hosted-tier tables (health4-register flow removed 2026-06-23)
-- healthkit_setup_codes and healthkit_api_keys were created in 002_hosted_tier.sql.
-- No live user data was ever written; app went self-hosted only before public launch.

DROP TABLE IF EXISTS public.healthkit_api_keys CASCADE;
DROP TABLE IF EXISTS public.healthkit_setup_codes CASCADE;
