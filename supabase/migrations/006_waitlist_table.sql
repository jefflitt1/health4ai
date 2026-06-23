-- health4.ai — Waitlist table (landing-page email capture)
-- Run via: Supabase Management API POST /v1/projects/{ref}/database/query
--
-- Captures the public.health4ai_waitlist table that backs the "Join waitlist"
-- forms on the landing page (web/src/pages/index.astro). Created live during an
-- earlier session but never committed to a migration — this file makes it
-- reproducible from a clean rebuild.
--
-- ROOT CAUSE of the 2026-06-22 "signup not working" bug: the anon_insert RLS
-- policy existed, but the anon role had NO table-level GRANT, so PostgreSQL
-- denied every insert (42501) before RLS was ever evaluated. The GRANT below is
-- the fix and MUST stay paired with the policy.

CREATE TABLE IF NOT EXISTS public.health4ai_waitlist (
    id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    email      text        NOT NULL UNIQUE,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- Data-quality guard on a deliberately public write path. anon can insert any
-- non-null text via the REST endpoint, so the DB (not the bypassable browser
-- type=email check) must be canonical. Length cap = RFC 5321 max (254).
ALTER TABLE public.health4ai_waitlist
    DROP CONSTRAINT IF EXISTS health4ai_waitlist_email_format;
ALTER TABLE public.health4ai_waitlist
    ADD CONSTRAINT health4ai_waitlist_email_format
    CHECK (char_length(email) <= 254 AND email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$');

-- Normalize (lowercase + trim) before insert/update so case/whitespace variants
-- collapse to one canonical row and the UNIQUE(email) constraint dedupes them.
CREATE OR REPLACE FUNCTION public.health4ai_waitlist_normalize_email()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.email := lower(btrim(NEW.email));
    RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_health4ai_waitlist_normalize ON public.health4ai_waitlist;
CREATE TRIGGER trg_health4ai_waitlist_normalize
    BEFORE INSERT OR UPDATE ON public.health4ai_waitlist
    FOR EACH ROW EXECUTE FUNCTION public.health4ai_waitlist_normalize_email();

-- RLS: anon may INSERT only (no read/update/delete from the public anon key).
ALTER TABLE public.health4ai_waitlist ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS anon_insert ON public.health4ai_waitlist;
CREATE POLICY anon_insert
    ON public.health4ai_waitlist
    FOR INSERT
    TO anon
    WITH CHECK (true);

-- Table-level grant — REQUIRED. Without this the policy is dead and every
-- landing-page signup returns 401 / 42501 "permission denied for table".
GRANT INSERT ON TABLE public.health4ai_waitlist TO anon;

-- service_role retains full access for admin/export (Supabase default).
GRANT ALL ON TABLE public.health4ai_waitlist TO service_role;
