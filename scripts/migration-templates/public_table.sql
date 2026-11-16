-- TEMPLATE: a new table in the `public` schema of a health4ai Supabase backend.
-- Copy to supabase/migrations/ and replace every <placeholder>. If the table is part of the schema customers
-- install, put it in supabase/bootstrap/001 + 002 instead and run scripts/build_schema_sql.sh. The grants lint
-- (scripts/check-migration-grants.py) reads this shape and fails a table without it; CI runs it on every pull request.
--
-- WHY THE GRANTS LIVE HERE: from 2026-10-30 Supabase no longer auto-grants anon / authenticated /
-- service_role on NEW public tables (new projects first), so a bare CREATE TABLE answers 42501 to supabase-js
-- and PostgREST until a GRANT exists. Existing tables keep their grants. Ship the grant in the same file.
-- Start CLOSED and open one role and one verb at a time. Do NOT write ALTER DEFAULT PRIVILEGES to
-- anon/authenticated, GRANT ... ON ALL TABLES to them, or any blanket grant (check rule G004).

create table if not exists public.<table_name> (
  id         uuid primary key default gen_random_uuid(),  -- uuid/identity keys need no sequence grant
  user_id    uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.<table_name> enable row level security;  -- FIRST, before any grant

-- 1. service_role: only if a server-side caller exists (an Edge Function, a script), and ONLY the verbs it uses.
--    It bypasses RLS, so it needs no policy. Name the caller, like the healthkit_metrics grant in bootstrap/002.
grant select, insert on public.<table_name> to service_role;  -- caller: <path>:<line>

-- 2. authenticated: ONLY the verbs the app calls, with a policy that pins every row to its owner.
grant select, delete on public.<table_name> to authenticated;  -- consumer: <path>:<line>
create policy <table_name>_select_own on public.<table_name>
  for select to authenticated using (auth.uid() = user_id);
create policy <table_name>_delete_own on public.<table_name>
  for delete to authenticated using (auth.uid() = user_id);

-- 3. anon: the default is NONE. The one deliberate exception is the waitlist form, a column-scoped INSERT.
--    Each GRANT to anon needs its own reason, on the grant or the comment block just above it:
-- -- anon-ok: <why the open internet may do this>
-- grant insert (<column>) on public.<table_name> to anon;

-- serial / bigserial column: also  grant usage, select on sequence public.<table_name>_<col>_seq to service_role;
--   (the platform change revokes sequence access too; `generated always as identity` does not need it)
-- A view is its own relation (create view, or create or replace view): create it with (security_invoker = on)
--   and grant select on it. Re-stating the grant on a replaced view is harmless and keeps the lint green.
-- A function is called through .rpc(): revoke execute from public, anon and authenticated, then
--   grant execute on function public.<fn>(<args>) to service_role;   (the lint does not check functions)
-- Closed to the Data API entirely (reached only through a direct database connection)?
--   delete sections 1-3 and put `-- data-api: none (<reason>)` on the line above CREATE TABLE. In a migration
--   wrapped in one DO block, the annotation (and any anon-ok reason) goes above the statement INSIDE the block.
