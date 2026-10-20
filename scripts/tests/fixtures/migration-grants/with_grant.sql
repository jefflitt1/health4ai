-- FIXTURE (must PASS check-migration-grants.py): the same table with its explicit grant.
create table if not exists public.example_widget (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now()
);

alter table public.example_widget enable row level security;

grant select, insert, update, delete on public.example_widget to service_role;

create policy example_widget_admin_all on public.example_widget
  for all using (public.is_admin());
