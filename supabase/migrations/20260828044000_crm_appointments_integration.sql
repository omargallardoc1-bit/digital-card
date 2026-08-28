alter table public.prospect_activities drop constraint if exists prospect_activities_activity_type_check;
alter table public.prospect_activities add constraint prospect_activities_activity_type_check check (activity_type in ('created','update','status_change','follow_up','note','manual','appointment'));

create or replace function public.create_public_appointment(target_card_id uuid, target_prospect_id uuid, requested_at timestamptz, target_service_id uuid default null::uuid, requested_duration_minutes integer default 30, appointment_notes text default null::text)
returns uuid
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  normalized_notes text;
  target_organization_id uuid;
  inserted_id uuid;
  s public.appointment_settings%rowtype;
  local_requested timestamp;
  local_weekday integer;
  local_time time;
  previous_status text;
begin
  if target_card_id is null or target_prospect_id is null or requested_at is null then raise exception using errcode='22023', message='Faltan datos para solicitar la cita.'; end if;
  if not private.card_appointments_enabled(target_card_id) then raise exception using errcode='42501', message='La agenda no está incluida para esta tarjeta.'; end if;
  select * into s from public.appointment_settings where card_id=target_card_id and enabled=true;
  if not found then raise exception using errcode='P0001', message='La agenda no está disponible.'; end if;
  if requested_duration_minutes is distinct from s.default_duration_minutes then raise exception using errcode='22023', message='La duración solicitada no es válida.'; end if;
  if requested_at < now()+make_interval(mins=>s.min_notice_minutes) or requested_at > now()+make_interval(days=>s.max_booking_days) then raise exception using errcode='22023', message='La fecha de la cita no es válida.'; end if;

  local_requested:=requested_at at time zone s.timezone;
  local_weekday:=extract(dow from local_requested)::int;
  local_time:=local_requested::time;
  if not exists(
    select 1 from public.appointment_availability_rules r
    where r.card_id=target_card_id and r.is_active=true and r.weekday=local_weekday
      and local_time>=r.start_time
      and local_time+make_interval(mins=>s.default_duration_minutes)<=r.end_time
      and mod(extract(epoch from (local_time-r.start_time))::bigint,(s.slot_interval_minutes*60)::bigint)=0
  ) then raise exception using errcode='22023', message='Ese horario no está disponible.'; end if;

  if exists(
    select 1 from public.appointment_blocks b
    where b.card_id=target_card_id
      and tstzrange(b.starts_at,b.ends_at,'[)') && tstzrange(requested_at,requested_at+make_interval(mins=>s.default_duration_minutes),'[)')
  ) then raise exception using errcode='P0001', message='Ese horario ya no está disponible.'; end if;

  if exists(
    select 1 from public.appointments a
    where a.card_id=target_card_id and a.status='confirmed'
      and tstzrange(a.scheduled_at,a.scheduled_at+make_interval(mins=>a.duration_minutes),'[)') && tstzrange(requested_at,requested_at+make_interval(mins=>s.default_duration_minutes),'[)')
  ) then raise exception using errcode='P0001', message='Ese horario ya no está disponible.'; end if;

  normalized_notes:=nullif(btrim(coalesce(appointment_notes,'')),'');
  if normalized_notes is not null and char_length(normalized_notes)>4000 then raise exception using errcode='22023', message='Las notas son demasiado largas.'; end if;
  select c.organization_id into target_organization_id from public.digital_cards c where c.id=target_card_id and c.status='published';
  if not found or target_organization_id is null then raise exception using errcode='P0001', message='La tarjeta no está disponible para citas.'; end if;
  select p.status into previous_status from public.prospects p where p.id=target_prospect_id and p.card_id=target_card_id for update;
  if not found then raise exception using errcode='22023', message='El prospecto no corresponde a la tarjeta.'; end if;
  if target_service_id is not null and not exists(select 1 from public.card_services cs where cs.id=target_service_id and cs.card_id=target_card_id) then raise exception using errcode='22023', message='El servicio no corresponde a la tarjeta.'; end if;

  insert into public.appointments(organization_id,card_id,prospect_id,service_id,scheduled_at,duration_minutes,status,notes)
  values(target_organization_id,target_card_id,target_prospect_id,target_service_id,requested_at,s.default_duration_minutes,'requested',normalized_notes)
  returning id into inserted_id;

  if previous_status not in ('won','lost') then
    update public.prospects set status='appointment',updated_at=now() where id=target_prospect_id;
  end if;

  insert into public.prospect_activities(organization_id,prospect_id,actor_user_id,activity_type,summary,details)
  values(target_organization_id,target_prospect_id,null,'appointment','Cita solicitada',jsonb_build_object(
    'appointment_id',inserted_id,
    'appointment_status','requested',
    'scheduled_at',requested_at,
    'service_id',target_service_id,
    'previous_status',previous_status,
    'status',case when previous_status in ('won','lost') then previous_status else 'appointment' end
  ));

  return inserted_id;
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

create or replace function public.list_organization_prospects(target_organization_id uuid, target_card_id uuid default null::uuid, requested_page integer default 1, requested_page_size integer default 50, sort_direction text default 'desc'::text)
returns table(items jsonb, total_count bigint, page_number integer, page_size integer)
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  effective_plan record;
  normalized_sort text;
  safe_page integer;
  safe_page_size integer;
  row_offset integer;
  matching_count bigint;
  result_items jsonb;
begin
  if (select auth.uid()) is null then raise exception using errcode='42501', message='Se requiere autenticación.'; end if;
  if target_organization_id is null or not exists (select 1 from public.organization_members member where member.organization_id=target_organization_id and member.user_id=(select auth.uid()) and member.status='active' and member.role in ('owner','admin','editor')) then raise exception using errcode='42501', message='No tienes permiso para consultar prospectos.'; end if;
  select plan_row.* into effective_plan from private.get_effective_plan(target_organization_id) as plan_row;
  if not found then raise exception using errcode='P0001', message='La organización no tiene una suscripción utilizable.'; end if;
  if target_card_id is not null and not exists(select 1 from public.digital_cards card where card.id=target_card_id and card.organization_id=target_organization_id) then raise exception using errcode='22023', message='La tarjeta no pertenece a la organización.'; end if;

  safe_page:=greatest(coalesce(requested_page,1),1);
  safe_page_size:=least(greatest(coalesce(requested_page_size,50),1),100);
  if safe_page>100000 then raise exception using errcode='22023', message='La página solicitada no es válida.'; end if;
  normalized_sort:=lower(btrim(coalesce(sort_direction,'desc')));
  if normalized_sort not in ('asc','desc') then raise exception using errcode='22023', message='El orden solicitado no es válido.'; end if;
  row_offset:=(safe_page-1)*safe_page_size;

  select count(*) into matching_count
  from public.prospects prospect join public.digital_cards card on card.id=prospect.card_id
  where card.organization_id=target_organization_id and (target_card_id is null or card.id=target_card_id);

  select coalesce(jsonb_agg(page_row.item order by
      case when normalized_sort='asc' then page_row.created_at end asc,
      case when normalized_sort='desc' then page_row.created_at end desc,
      case when normalized_sort='asc' then page_row.prospect_id end asc,
      case when normalized_sort='desc' then page_row.prospect_id end desc), '[]'::jsonb)
  into result_items
  from (
    select prospect.created_at,prospect.id as prospect_id,
      jsonb_build_object(
        'id',prospect.id,'card_id',prospect.card_id,'name',prospect.name,'phone',prospect.whatsapp,'email',prospect.email,'card_name',card.name,
        'created_at',prospect.created_at,'source',prospect.source,'consent_given',prospect.consent_given,'consent_at',prospect.consent_at,'consent_version',prospect.consent_version,
        'status',prospect.status,'tag',prospect.tag,'notes',prospect.notes,'next_follow_up_at',prospect.next_follow_up_at,'updated_at',prospect.updated_at,
        'latest_appointment',case when ap.id is null then null else jsonb_build_object(
          'id',ap.id,'status',ap.status,'scheduled_at',ap.scheduled_at,'duration_minutes',ap.duration_minutes,'service_id',ap.service_id,'service_title',svc.title,'notes',ap.notes,'confirmed_at',ap.confirmed_at,'cancelled_at',ap.cancelled_at
        ) end
      ) as item
    from public.prospects prospect
    join public.digital_cards card on card.id=prospect.card_id
    left join lateral (
      select a.* from public.appointments a where a.prospect_id=prospect.id
      order by case when a.status in ('requested','confirmed','rescheduled') and a.scheduled_at>=now() then 0 else 1 end, a.scheduled_at desc, a.created_at desc limit 1
    ) ap on true
    left join public.card_services svc on svc.id=ap.service_id
    where card.organization_id=target_organization_id and (target_card_id is null or card.id=target_card_id)
    order by
      case when normalized_sort='asc' then prospect.created_at end asc,
      case when normalized_sort='desc' then prospect.created_at end desc,
      case when normalized_sort='asc' then prospect.id end asc,
      case when normalized_sort='desc' then prospect.id end desc
    limit safe_page_size offset row_offset
  ) page_row;

  return query select result_items,matching_count,safe_page,safe_page_size;
end;
$function$;