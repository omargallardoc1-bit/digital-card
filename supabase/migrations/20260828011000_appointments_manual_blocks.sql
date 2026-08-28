begin;

create table if not exists public.appointment_blocks (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  card_id uuid not null references public.digital_cards(id) on delete cascade,
  branch_id uuid references public.appointment_branches(id) on delete cascade,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  source text not null default 'manual' check (source in ('manual','external','google_calendar','outlook','other')),
  note text,
  created_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint appointment_blocks_time_check check (starts_at < ends_at),
  constraint appointment_blocks_note_check check (note is null or char_length(note) <= 1000)
);

create index if not exists appointment_blocks_card_time_idx on public.appointment_blocks(card_id,starts_at,ends_at);
create index if not exists appointment_blocks_branch_time_idx on public.appointment_blocks(branch_id,starts_at,ends_at) where branch_id is not null;

alter table public.appointment_blocks enable row level security;
revoke all on table public.appointment_blocks from anon, authenticated;
grant select, insert, update, delete on table public.appointment_blocks to service_role;

-- Organization RPCs for listing, creating and deleting blocked time are defined
-- in production by migration appointments_manual_blocks.
-- Public slot generation and appointment creation also reject overlaps with blocks.

commit;
