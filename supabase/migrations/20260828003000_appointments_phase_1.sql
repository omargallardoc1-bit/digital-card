-- MX Business Card — Citas Fase 1
-- Backend aislado para solicitudes de cita ligadas a tarjeta, servicio y prospecto.
-- No expone la tabla directamente al navegador: toda operación pasa por RPC.

begin;

do $preconditions$
begin
  if to_regclass('public.digital_cards') is null
     or to_regclass('public.organizations') is null
     or to_regclass('public.organization_members') is null
     or to_regclass('public.prospects') is null
     or to_regclass('public.card_services') is null then
    raise exception 'Falta el núcleo requerido para Citas Fase 1.';
  end if;
end;
$preconditions$;

create table public.appointments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  card_id uuid not null references public.digital_cards(id) on delete cascade,
  prospect_id uuid not null references public.prospects(id) on delete cascade,
  service_id uuid references public.card_services(id) on delete set null,
  scheduled_at timestamptz not null,
  duration_minutes integer not null default 30,
  status text not null default 'requested',
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  confirmed_at timestamptz,
  cancelled_at timestamptz,
  constraint appointments_duration_check check (duration_minutes between 5 and 480),
  constraint appointments_status_check check (status in ('requested','confirmed','rescheduled','cancelled','completed','no_show')),
  constraint appointments_notes_length_check check (notes is null or char_length(notes) <= 4000)
);

create index appointments_org_scheduled_idx
  on public.appointments (organization_id, scheduled_at desc);

create index appointments_card_scheduled_idx
  on public.appointments (card_id, scheduled_at desc);

create index appointments_prospect_idx
  on public.appointments (prospect_id, scheduled_at desc);

create unique index appointments_card_slot_unique_idx
  on public.appointments (card_id, scheduled_at)
  where status in ('requested','confirmed','rescheduled');

alter table public.appointments enable row level security;

-- El cliente no toca la tabla directamente. RPCs controlan lectura y escritura.
revoke all on table public.appointments from anon, authenticated;
grant select, insert, update, delete on table public.appointments to service_role;

create or replace function public.create_public_appointment(
  target_card_id uuid,
  target_prospect_id uuid,
  requested_at timestamptz,
  target_service_id uuid default null,
  requested_duration_minutes integer default 30,
  appointment_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  normalized_notes text;
  target_organization_id uuid;
  inserted_id uuid;
begin
  if target_card_id is null or target_prospect_id is null or requested_at is null then
    raise exception using errcode='22023', message='Faltan datos para solicitar la cita.';
  end if;

  if requested_at <= now() or requested_at > now() + interval '180 days' then
    raise exception using errcode='22023', message='La fecha de la cita no es válida.';
  end if;

  if requested_duration_minutes is null or requested_duration_minutes < 5 or requested_duration_minutes > 480 then
    raise exception using errcode='22023', message='La duración de la cita no es válida.';
  end if;

  normalized_notes := nullif(btrim(coalesce(appointment_notes,'')), '');
  if normalized_notes is not null and char_length(normalized_notes) > 4000 then
    raise exception using errcode='22023', message='Las notas son demasiado largas.';
  end if;

  select card.organization_id
    into target_organization_id
  from public.digital_cards as card
  where card.id = target_card_id
    and card.status = 'published';

  if not found or target_organization_id is null then
    raise exception using errcode='P0001', message='La tarjeta no está disponible para citas.';
  end if;

  if not exists (
    select 1
    from public.prospects as prospect
    where prospect.id = target_prospect_id
      and prospect.card_id = target_card_id
  ) then
    raise exception using errcode='22023', message='El prospecto no corresponde a la tarjeta.';
  end if;

  if target_service_id is not null and not exists (
    select 1
    from public.card_services as service
    where service.id = target_service_id
      and service.card_id = target_card_id
  ) then
    raise exception using errcode='22023', message='El servicio no corresponde a la tarjeta.';
  end if;

  insert into public.appointments (
    organization_id, card_id, prospect_id, service_id,
    scheduled_at, duration_minutes, status, notes
  ) values (
    target_organization_id, target_card_id, target_prospect_id, target_service_id,
    requested_at, requested_duration_minutes, 'requested', normalized_notes
  )
  returning id into inserted_id;

  return inserted_id;
exception
  when unique_violation then
    raise exception using errcode='P0001', message='Ese horario ya no está disponible.';
end;
$function$;

create or replace function public.list_organization_appointments(
  target_organization_id uuid,
  target_card_id uuid default null,
  window_start timestamptz default null,
  window_end timestamptz default null
)
returns table(items jsonb)
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  result_items jsonb;
begin
  if (select auth.uid()) is null then
    raise exception using errcode='42501', message='Se requiere autenticación.';
  end if;

  if target_organization_id is null or not exists (
    select 1
    from public.organization_members as member
    where member.organization_id = target_organization_id
      and member.user_id = (select auth.uid())
      and member.status = 'active'
      and member.role in ('owner','admin','editor')
  ) then
    raise exception using errcode='42501', message='No tienes permiso para consultar citas.';
  end if;

  if target_card_id is not null and not exists (
    select 1 from public.digital_cards as card
    where card.id = target_card_id and card.organization_id = target_organization_id
  ) then
    raise exception using errcode='22023', message='La tarjeta no pertenece a la organización.';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', a.id,
    'card_id', a.card_id,
    'card_name', c.name,
    'prospect_id', a.prospect_id,
    'prospect_name', p.name,
    'phone', p.whatsapp,
    'email', p.email,
    'service_id', a.service_id,
    'service_title', s.title,
    'scheduled_at', a.scheduled_at,
    'duration_minutes', a.duration_minutes,
    'status', a.status,
    'notes', a.notes,
    'created_at', a.created_at,
    'confirmed_at', a.confirmed_at,
    'cancelled_at', a.cancelled_at
  ) order by a.scheduled_at asc), '[]'::jsonb)
  into result_items
  from public.appointments a
  join public.digital_cards c on c.id = a.card_id
  join public.prospects p on p.id = a.prospect_id
  left join public.card_services s on s.id = a.service_id
  where a.organization_id = target_organization_id
    and (target_card_id is null or a.card_id = target_card_id)
    and (window_start is null or a.scheduled_at >= window_start)
    and (window_end is null or a.scheduled_at < window_end);

  return query select result_items;
end;
$function$;

create or replace function public.update_organization_appointment(
  target_organization_id uuid,
  target_appointment_id uuid,
  new_status text,
  new_scheduled_at timestamptz default null,
  new_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  normalized_status text;
  normalized_notes text;
  current_row public.appointments%rowtype;
  updated_row public.appointments%rowtype;
begin
  if (select auth.uid()) is null then
    raise exception using errcode='42501', message='Se requiere autenticación.';
  end if;

  if target_organization_id is null or not exists (
    select 1
    from public.organization_members as member
    where member.organization_id = target_organization_id
      and member.user_id = (select auth.uid())
      and member.status = 'active'
      and member.role in ('owner','admin','editor')
  ) then
    raise exception using errcode='42501', message='No tienes permiso para actualizar citas.';
  end if;

  normalized_status := lower(btrim(coalesce(new_status,'')));
  if normalized_status not in ('requested','confirmed','rescheduled','cancelled','completed','no_show') then
    raise exception using errcode='22023', message='El estado de la cita no es válido.';
  end if;

  normalized_notes := nullif(btrim(coalesce(new_notes,'')), '');
  if normalized_notes is not null and char_length(normalized_notes) > 4000 then
    raise exception using errcode='22023', message='Las notas son demasiado largas.';
  end if;

  select * into current_row
  from public.appointments
  where id = target_appointment_id
    and organization_id = target_organization_id
  for update;

  if not found then
    raise exception using errcode='P0001', message='La cita no existe.';
  end if;

  if new_scheduled_at is not null and new_scheduled_at <= now() and normalized_status in ('requested','confirmed','rescheduled') then
    raise exception using errcode='22023', message='La nueva fecha debe estar en el futuro.';
  end if;

  update public.appointments
  set status = normalized_status,
      scheduled_at = coalesce(new_scheduled_at, scheduled_at),
      notes = normalized_notes,
      confirmed_at = case when normalized_status='confirmed' then coalesce(confirmed_at, now()) else confirmed_at end,
      cancelled_at = case when normalized_status='cancelled' then coalesce(cancelled_at, now()) else cancelled_at end,
      updated_at = now()
  where id = target_appointment_id
  returning * into updated_row;

  return jsonb_build_object(
    'id', updated_row.id,
    'scheduled_at', updated_row.scheduled_at,
    'status', updated_row.status,
    'notes', updated_row.notes,
    'confirmed_at', updated_row.confirmed_at,
    'cancelled_at', updated_row.cancelled_at,
    'updated_at', updated_row.updated_at
  );
exception
  when unique_violation then
    raise exception using errcode='P0001', message='Ese horario ya no está disponible.';
end;
$function$;

-- Functions are API endpoints: revoke PUBLIC and grant only intended roles.
revoke all on function public.create_public_appointment(uuid,uuid,timestamptz,uuid,integer,text) from public;
revoke all on function public.list_organization_appointments(uuid,uuid,timestamptz,timestamptz) from public;
revoke all on function public.update_organization_appointment(uuid,uuid,text,timestamptz,text) from public;

grant execute on function public.create_public_appointment(uuid,uuid,timestamptz,uuid,integer,text) to anon, authenticated, service_role;
grant execute on function public.list_organization_appointments(uuid,uuid,timestamptz,timestamptz) to authenticated, service_role;
grant execute on function public.update_organization_appointment(uuid,uuid,text,timestamptz,text) to authenticated, service_role;

commit;
