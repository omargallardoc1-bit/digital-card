-- Citas Fase 2: capacidad por plan, activación por tarjeta, timezone y disponibilidad.
-- Producción usa capabilities.appointments_enabled; la agenda de cada tarjeta inicia desactivada.

begin;

update public.plans set capabilities=jsonb_set(capabilities,'{appointments_enabled}','false'::jsonb,true),updated_at=now()
where code in ('conecta-card-esencial','prueba-invitaciones-2-miembros');
update public.plans set capabilities=jsonb_set(capabilities,'{appointments_enabled}','true'::jsonb,true),updated_at=now()
where code in ('conecta-card-independiente','conecta-card-pyme','conecta-card-empresarial');

create table if not exists public.appointment_settings(
 card_id uuid primary key references public.digital_cards(id) on delete cascade,
 enabled boolean not null default false,
 timezone text not null default 'UTC',
 default_duration_minutes integer not null default 30 check(default_duration_minutes between 5 and 480),
 slot_interval_minutes integer not null default 30 check(slot_interval_minutes between 5 and 240),
 min_notice_minutes integer not null default 60 check(min_notice_minutes between 0 and 43200),
 max_booking_days integer not null default 60 check(max_booking_days between 1 and 365),
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.appointment_availability_rules(
 id uuid primary key default gen_random_uuid(),
 card_id uuid not null references public.digital_cards(id) on delete cascade,
 weekday smallint not null check(weekday between 0 and 6),
 start_time time not null,end_time time not null,is_active boolean not null default true,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 constraint appointment_availability_time_check check(start_time<end_time),
 constraint appointment_availability_unique unique(card_id,weekday,start_time,end_time)
);

create index if not exists appointment_availability_card_weekday_idx on public.appointment_availability_rules(card_id,weekday) where is_active;
alter table public.appointment_settings enable row level security;
alter table public.appointment_availability_rules enable row level security;
revoke all on table public.appointment_settings from anon,authenticated;
revoke all on table public.appointment_availability_rules from anon,authenticated;
grant select,insert,update,delete on table public.appointment_settings to service_role;
grant select,insert,update,delete on table public.appointment_availability_rules to service_role;

-- Las RPC completas get/update settings, list_public_appointment_slots y la versión endurecida
-- de create_public_appointment están aplicadas en producción. Se mantienen SECURITY DEFINER,
-- search_path pg_catalog y EXECUTE mínimo por rol.

commit;
