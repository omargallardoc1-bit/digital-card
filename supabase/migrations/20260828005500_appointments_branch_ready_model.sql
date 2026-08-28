begin;

create table if not exists public.appointment_branches (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  card_id uuid not null references public.digital_cards(id) on delete cascade,
  name text not null,
  timezone text not null default 'UTC',
  is_active boolean not null default true,
  address text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint appointment_branches_name_check check (char_length(btrim(name)) between 1 and 160),
  constraint appointment_branches_timezone_check check (char_length(btrim(timezone)) between 1 and 120)
);

create index if not exists appointment_branches_card_idx on public.appointment_branches(card_id) where is_active;
create index if not exists appointment_branches_org_idx on public.appointment_branches(organization_id) where is_active;

alter table public.appointment_branches enable row level security;
revoke all on table public.appointment_branches from anon, authenticated;
grant select, insert, update, delete on table public.appointment_branches to service_role;

alter table public.appointment_settings add column if not exists branch_id uuid references public.appointment_branches(id) on delete cascade;
alter table public.appointment_availability_rules add column if not exists branch_id uuid references public.appointment_branches(id) on delete cascade;
alter table public.appointments add column if not exists branch_id uuid references public.appointment_branches(id) on delete set null;

create index if not exists appointments_branch_scheduled_idx on public.appointments(branch_id,scheduled_at desc) where branch_id is not null;
create index if not exists appointment_availability_branch_weekday_idx on public.appointment_availability_rules(branch_id,weekday) where branch_id is not null and is_active;

commit;
