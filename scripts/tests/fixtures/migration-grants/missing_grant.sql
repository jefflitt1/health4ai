-- FIXTURE (must FAIL check-migration-grants.py with G001): a new public table with RLS but no GRANT.
-- After 2026-10-30 this table is unreachable through the Data API, including for service_role.
create table if not exists public.example_widget (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now()
);

alter table public.example_widget enable row level security;

create policy example_widget_admin_all on public.example_widget
  for all using (public.is_admin());
