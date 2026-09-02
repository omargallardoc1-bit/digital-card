begin;

create or replace function public.create_organization_appointment_block(
  target_organization_id uuid,
  target_card_id uuid,
  block_starts_at timestamptz,
  block_ends_at timestamptz,
  block_source text default 'manual',
  block_note text default null,
  target_branch_id uuid default null
)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  inserted_id uuid;
  normalized_source text:=lower(btrim(coalesce(block_source,'manual')));
  normalized_note text:=nullif(btrim(coalesce(block_note,'')),'');
begin
  if (select auth.uid()) is null then raise exception using errcode='42501', message='Se requiere autenticación.'; end if;
  if not exists (
    select 1 from public.organization_members m
    where m.organization_id=target_organization_id and m.user_id=(select auth.uid()) and m.status='active' and m.role in ('owner','admin','editor')
  ) then raise exception using errcode='42501', message='No tienes permiso para bloquear horarios.'; end if;
  if not exists(select 1 from public.digital_cards c where c.id=target_card_id and c.organization_id=target_organization_id) then
    raise exception using errcode='22023', message='La tarjeta no pertenece a la organización.';
  end if;
  if not private.card_appointments_enabled(target_card_id) then
    raise exception using errcode='42501', message='El plan de esta tarjeta no incluye agenda.';
  end if;
  if block_starts_at is null or block_ends_at is null or block_starts_at >= block_ends_at then
    raise exception using errcode='22023', message='El rango de bloqueo no es válido.';
  end if;
  if normalized_source not in ('manual','external','google_calendar','outlook','other') then
    raise exception using errcode='22023', message='El origen del bloqueo no es válido.';
  end if;
  if normalized_note is not null and char_length(normalized_note)>1000 then
    raise exception using errcode='22023', message='La nota es demasiado larga.';
  end if;
  if target_branch_id is not null and not exists(select 1 from public.appointment_branches b where b.id=target_branch_id and b.card_id=target_card_id and b.organization_id=target_organization_id) then
    raise exception using errcode='22023', message='La sucursal no corresponde a la tarjeta.';
  end if;
  insert into public.appointment_blocks(organization_id,card_id,branch_id,starts_at,ends_at,source,note,created_by)
  values(target_organization_id,target_card_id,target_branch_id,block_starts_at,block_ends_at,normalized_source,normalized_note,(select auth.uid()))
  returning id into inserted_id;
  return inserted_id;
end;
$function$;

create or replace function public.list_organization_appointment_blocks(
  target_organization_id uuid,
  target_card_id uuid default null,
  from_at timestamptz default now(),
  to_at timestamptz default now() + interval '90 days'
)
returns table(id uuid, card_id uuid, branch_id uuid, starts_at timestamptz, ends_at timestamptz, source text, note text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path to 'pg_catalog'
as $function$
begin
  if (select auth.uid()) is null then raise exception using errcode='42501', message='Se requiere autenticación.'; end if;
  if not exists (
    select 1 from public.organization_members m
    where m.organization_id=target_organization_id and m.user_id=(select auth.uid()) and m.status='active' and m.role in ('owner','admin','editor')
  ) then raise exception using errcode='42501', message='No tienes permiso para consultar bloqueos.'; end if;
  if target_card_id is not null and not exists(
    select 1 from public.digital_cards c where c.id=target_card_id and c.organization_id=target_organization_id
  ) then
    raise exception using errcode='22023', message='La tarjeta no pertenece a la organización.';
  end if;
  if target_card_id is not null and not private.card_appointments_enabled(target_card_id) then
    raise exception using errcode='42501', message='El plan de esta tarjeta no incluye agenda.';
  end if;
  return query
  select b.id,b.card_id,b.branch_id,b.starts_at,b.ends_at,b.source,b.note,b.created_at
  from public.appointment_blocks b
  join public.digital_cards c on c.id = b.card_id
  where b.organization_id=target_organization_id
    and (target_card_id is null or b.card_id=target_card_id)
    and private.card_appointments_enabled(b.card_id)
    and b.ends_at > from_at and b.starts_at < to_at
  order by b.starts_at asc;
end;
$function$;

create or replace function public.delete_organization_appointment_block(target_organization_id uuid, target_block_id uuid)
returns boolean
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  target_card_id uuid;
begin
  if (select auth.uid()) is null then raise exception using errcode='42501', message='Se requiere autenticación.'; end if;
  if not exists (
    select 1 from public.organization_members m
    where m.organization_id=target_organization_id and m.user_id=(select auth.uid()) and m.status='active' and m.role in ('owner','admin','editor')
  ) then raise exception using errcode='42501', message='No tienes permiso para liberar horarios.'; end if;

  select b.card_id into target_card_id
  from public.appointment_blocks b
  where b.id=target_block_id and b.organization_id=target_organization_id;

  if not found then
    return false;
  end if;

  if not private.card_appointments_enabled(target_card_id) then
    raise exception using errcode='42501', message='El plan de esta tarjeta no incluye agenda.';
  end if;

  delete from public.appointment_blocks b where b.id=target_block_id and b.organization_id=target_organization_id;
  return found;
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

  if target_card_id is not null and not private.card_appointments_enabled(target_card_id) then
    raise exception using errcode='42501', message='El plan de esta tarjeta no incluye agenda.';
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
    and private.card_appointments_enabled(a.card_id)
    and (window_start is null or a.scheduled_at >= window_start)
    and (window_end is null or a.scheduled_at < window_end);

  return query select result_items;
end;
$function$;

create or replace function public.update_organization_appointment(target_organization_id uuid, target_appointment_id uuid, new_status text, new_scheduled_at timestamptz default null::timestamptz, new_notes text default null::text)
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
  effective_scheduled_at timestamptz;
  status_label text;
begin
  if (select auth.uid()) is null then raise exception using errcode='42501', message='Se requiere autenticación.'; end if;
  if target_organization_id is null or not exists (
    select 1 from public.organization_members member
    where member.organization_id=target_organization_id and member.user_id=(select auth.uid()) and member.status='active' and member.role in ('owner','admin','editor')
  ) then raise exception using errcode='42501', message='No tienes permiso para actualizar citas.'; end if;

  normalized_status:=lower(btrim(coalesce(new_status,'')));
  if normalized_status not in ('requested','confirmed','rescheduled','cancelled','completed','no_show') then raise exception using errcode='22023', message='El estado de la cita no es válido.'; end if;
  normalized_notes:=nullif(btrim(coalesce(new_notes,'')),'');
  if normalized_notes is not null and char_length(normalized_notes)>4000 then raise exception using errcode='22023', message='Las notas son demasiado largas.'; end if;

  select * into current_row from public.appointments where id=target_appointment_id and organization_id=target_organization_id for update;
  if not found then raise exception using errcode='P0001', message='La cita no existe.'; end if;

  if not private.card_appointments_enabled(current_row.card_id) then
    raise exception using errcode='42501', message='El plan de esta tarjeta no incluye agenda.';
  end if;

  effective_scheduled_at:=coalesce(new_scheduled_at,current_row.scheduled_at);
  if effective_scheduled_at<=now() and normalized_status in ('requested','confirmed','rescheduled') then raise exception using errcode='22023', message='La fecha de la cita debe estar en el futuro.'; end if;
  if new_scheduled_at is not null and new_scheduled_at is distinct from current_row.scheduled_at and normalized_status='confirmed' then raise exception using errcode='22023', message='Una cita reprogramada debe guardarse como Reprogramada y confirmarse nuevamente.'; end if;

  if normalized_status='confirmed' then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(current_row.card_id::text,0));
    if exists(select 1 from public.appointment_blocks b where b.card_id=current_row.card_id and tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(effective_scheduled_at,effective_scheduled_at+make_interval(mins=>current_row.duration_minutes),'[)')) then raise exception using errcode='P0001', message='Ese horario está bloqueado y no puede confirmarse.'; end if;
    if exists(select 1 from public.appointments a where a.card_id=current_row.card_id and a.id<>current_row.id and a.status='confirmed' and tstzrange(a.scheduled_at,a.scheduled_at+make_interval(mins=>a.duration_minutes),'[)') && tstzrange(effective_scheduled_at,effective_scheduled_at+make_interval(mins=>current_row.duration_minutes),'[)')) then raise exception using errcode='P0001', message='Ya existe otra cita confirmada que se empalma con ese horario. Reprograma una de las solicitudes.'; end if;
  end if;

  update public.appointments
  set status=normalized_status,
      scheduled_at=effective_scheduled_at,
      notes=normalized_notes,
      confirmed_at=case when normalized_status='confirmed' then coalesce(confirmed_at,now()) when normalized_status in ('requested','rescheduled') then null else confirmed_at end,
      cancelled_at=case when normalized_status='cancelled' then coalesce(cancelled_at,now()) else cancelled_at end,
      updated_at=now()
  where id=target_appointment_id
  returning * into updated_row;

  status_label:=case normalized_status when 'requested' then 'Solicitada' when 'confirmed' then 'Confirmada' when 'rescheduled' then 'Reprogramada' when 'cancelled' then 'Cancelada' when 'completed' then 'Atendida' when 'no_show' then 'No asistió' end;
  if current_row.status is distinct from updated_row.status or current_row.scheduled_at is distinct from updated_row.scheduled_at or current_row.notes is distinct from updated_row.notes then
    insert into public.prospect_activities(organization_id,prospect_id,actor_user_id,activity_type,summary,details)
    values(target_organization_id,updated_row.prospect_id,(select auth.uid()),'appointment','Cita: '||status_label,jsonb_build_object(
      'appointment_id',updated_row.id,
      'previous_appointment_status',current_row.status,
      'appointment_status',updated_row.status,
      'previous_scheduled_at',current_row.scheduled_at,
      'scheduled_at',updated_row.scheduled_at,
      'notes_changed',current_row.notes is distinct from updated_row.notes
    ));
  end if;

  return jsonb_build_object('id',updated_row.id,'scheduled_at',updated_row.scheduled_at,'status',updated_row.status,'notes',updated_row.notes,'confirmed_at',updated_row.confirmed_at,'cancelled_at',updated_row.cancelled_at,'updated_at',updated_row.updated_at);
exception when unique_violation then
  raise exception using errcode='P0001', message='Ya existe otra cita confirmada en ese horario.';
end;
$function$;

revoke all on function public.create_organization_appointment_block(uuid,uuid,timestamptz,timestamptz,text,text,uuid) from public;
revoke all on function public.list_organization_appointment_blocks(uuid,uuid,timestamptz,timestamptz) from public;
revoke all on function public.delete_organization_appointment_block(uuid,uuid) from public;
revoke all on function public.list_organization_appointments(uuid,uuid,timestamptz,timestamptz) from public;
revoke all on function public.update_organization_appointment(uuid,uuid,text,timestamptz,text) from public;

grant execute on function public.create_organization_appointment_block(uuid,uuid,timestamptz,timestamptz,text,text,uuid) to authenticated, service_role;
grant execute on function public.list_organization_appointment_blocks(uuid,uuid,timestamptz,timestamptz) to authenticated, service_role;
grant execute on function public.delete_organization_appointment_block(uuid,uuid) to authenticated, service_role;
grant execute on function public.list_organization_appointments(uuid,uuid,timestamptz,timestamptz) to authenticated, service_role;
grant execute on function public.update_organization_appointment(uuid,uuid,text,timestamptz,text) to authenticated, service_role;

commit;
