create or replace function private.card_mini_crm_enabled(target_card_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog'
as $function$
  select coalesce((plan_row.capabilities->>'mini_crm_enabled')::boolean,false)
  from private.get_effective_card_plan(target_card_id) as plan_row
  limit 1;
$function$;

revoke all on function private.card_mini_crm_enabled(uuid) from public, anon, authenticated, service_role;

create or replace function public.get_organization_prospect_funnel(target_organization_id uuid, target_card_id uuid default null::uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  result jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Se requiere autenticación.';
  end if;

  if target_organization_id is null or not exists (
    select 1 from public.organization_members m
    where m.organization_id=target_organization_id
      and m.user_id=auth.uid()
      and m.status='active'
      and m.role in ('owner','admin','editor')
  ) then
    raise exception using errcode='42501', message='No tienes permiso para consultar el embudo comercial.';
  end if;

  if target_card_id is not null then
    if not exists (
      select 1 from public.digital_cards c
      where c.id=target_card_id and c.organization_id=target_organization_id
    ) then
      raise exception using errcode='22023', message='La tarjeta no pertenece a la organización.';
    end if;
    if not private.card_mini_crm_enabled(target_card_id) then
      raise exception using errcode='42501', message='El plan de esta tarjeta no incluye Mini CRM.';
    end if;
  end if;

  select jsonb_build_object(
    'prospects', count(*),
    'new', count(*) filter(where p.status='new'),
    'contacted', count(*) filter(where p.status='contacted'),
    'interested', count(*) filter(where p.status='interested'),
    'appointment', count(*) filter(where p.status='appointment'),
    'proposal', count(*) filter(where p.status='proposal'),
    'won', count(*) filter(where p.status='won'),
    'lost', count(*) filter(where p.status='lost'),
    'follow_up', count(*) filter(where p.status='follow_up'),
    'customers', count(*) filter(where p.status='customer'),
    'discarded', count(*) filter(where p.status='discarded'),
    'worked', count(*) filter(where p.status in ('contacted','interested','appointment','proposal','won','follow_up','customer')),
    'prospect_to_customer_rate', case when count(*)=0 then 0 else round((count(*) filter(where p.status in ('won','customer')))::numeric*100/count(*),1) end
  ) into result
  from public.prospects p
  join public.digital_cards c on c.id=p.card_id
  where c.organization_id=target_organization_id
    and private.card_mini_crm_enabled(c.id)
    and (target_card_id is null or c.id=target_card_id);

  return result;
end;
$function$;

create or replace function public.list_organization_prospect_activities(target_organization_id uuid, target_prospect_id uuid, requested_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  safe_limit integer;
  result jsonb;
begin
  if (select auth.uid()) is null then
    raise exception using errcode='42501', message='Se requiere autenticación.';
  end if;

  if target_organization_id is null or not exists (
    select 1 from public.organization_members m
    where m.organization_id=target_organization_id
      and m.user_id=(select auth.uid())
      and m.status='active'
      and m.role in ('owner','admin','editor')
  ) then
    raise exception using errcode='42501', message='No tienes permiso para consultar el historial.';
  end if;

  if not exists (
    select 1
    from public.prospects p
    join public.digital_cards c on c.id=p.card_id
    where p.id=target_prospect_id
      and c.organization_id=target_organization_id
      and private.card_mini_crm_enabled(c.id)
  ) then
    raise exception using errcode='22023', message='El prospecto no pertenece a una tarjeta con Mini CRM.';
  end if;

  safe_limit := least(greatest(coalesce(requested_limit,100),1),200);

  select coalesce(jsonb_agg(x.item order by x.created_at desc), '[]'::jsonb)
  into result
  from (
    select a.created_at,
      jsonb_build_object(
        'id',a.id,
        'activity_type',a.activity_type,
        'summary',a.summary,
        'details',a.details,
        'actor_user_id',a.actor_user_id,
        'created_at',a.created_at
      ) as item
    from public.prospect_activities a
    where a.organization_id=target_organization_id
      and a.prospect_id=target_prospect_id
    order by a.created_at desc
    limit safe_limit
  ) x;

  return result;
end;
$function$;

create or replace function public.list_organization_prospects(target_organization_id uuid, target_card_id uuid default null::uuid, requested_page integer default 1, requested_page_size integer default 50, sort_direction text default 'desc'::text)
returns table(items jsonb, total_count bigint, page_number integer, page_size integer)
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  normalized_sort text;
  safe_page integer;
  safe_page_size integer;
  row_offset integer;
  matching_count bigint;
  result_items jsonb;
begin
  if (select auth.uid()) is null then
    raise exception using errcode='42501', message='Se requiere autenticación.';
  end if;
  if target_organization_id is null or not exists (
    select 1 from public.organization_members member
    where member.organization_id=target_organization_id
      and member.user_id=(select auth.uid())
      and member.status='active'
      and member.role in ('owner','admin','editor')
  ) then
    raise exception using errcode='42501', message='No tienes permiso para consultar prospectos.';
  end if;
  if not exists (select 1 from private.get_effective_plan(target_organization_id)) then
    raise exception using errcode='P0001', message='La organización no tiene una suscripción utilizable.';
  end if;
  if target_card_id is not null then
    if not exists (
      select 1 from public.digital_cards card
      where card.id=target_card_id and card.organization_id=target_organization_id
    ) then
      raise exception using errcode='22023', message='La tarjeta no pertenece a la organización.';
    end if;
    if not private.card_mini_crm_enabled(target_card_id) then
      raise exception using errcode='42501', message='El plan de esta tarjeta no incluye Mini CRM.';
    end if;
  end if;

  safe_page:=greatest(coalesce(requested_page,1),1);
  safe_page_size:=least(greatest(coalesce(requested_page_size,50),1),100);
  if safe_page>100000 then raise exception using errcode='22023', message='La página solicitada no es válida.'; end if;
  normalized_sort:=lower(btrim(coalesce(sort_direction,'desc')));
  if normalized_sort not in ('asc','desc') then raise exception using errcode='22023', message='El orden solicitado no es válido.'; end if;
  row_offset:=(safe_page-1)*safe_page_size;

  select count(*) into matching_count
  from public.prospects prospect
  join public.digital_cards card on card.id=prospect.card_id
  where card.organization_id=target_organization_id
    and private.card_mini_crm_enabled(card.id)
    and (target_card_id is null or card.id=target_card_id);

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
    where card.organization_id=target_organization_id
      and private.card_mini_crm_enabled(card.id)
      and (target_card_id is null or card.id=target_card_id)
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

create or replace function public.update_organization_prospect(target_organization_id uuid, target_prospect_id uuid, new_status text default null::text, new_tag text default null::text, new_notes text default null::text, new_next_follow_up_at timestamptz default null::timestamptz)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  result_row public.prospects%rowtype;
  previous_row public.prospects%rowtype;
  normalized_status text;
  normalized_tag text;
  change_parts text[]:=array[]::text[];
  activity_summary text;
begin
  if (select auth.uid()) is null then raise exception using errcode='42501',message='Se requiere autenticación.'; end if;
  if target_organization_id is null or not exists (
    select 1 from public.organization_members m
    where m.organization_id=target_organization_id
      and m.user_id=(select auth.uid())
      and m.status='active'
      and m.role in ('owner','admin','editor')
  ) then raise exception using errcode='42501',message='No tienes permiso para administrar prospectos.'; end if;
  select p.* into previous_row
  from public.prospects p
  join public.digital_cards c on c.id=p.card_id
  where p.id=target_prospect_id
    and c.organization_id=target_organization_id
    and private.card_mini_crm_enabled(c.id);
  if not found then raise exception using errcode='22023',message='El prospecto no pertenece a una tarjeta con Mini CRM.'; end if;
  normalized_status:=coalesce(new_status,previous_row.status);
  normalized_tag:=case when new_tag is null then previous_row.tag else nullif(btrim(new_tag),'') end;
  if normalized_status not in ('new','contacted','follow_up','customer','discarded','interested','appointment','proposal','won','lost') then
    raise exception using errcode='22023',message='El estado no es válido.';
  end if;
  if normalized_tag is not null and normalized_tag not in ('prospect','customer','supplier','alliance','other') then
    raise exception using errcode='22023',message='La etiqueta no es válida.';
  end if;
  update public.prospects p set status=normalized_status,tag=normalized_tag,
    notes=case when new_notes is null then p.notes else nullif(btrim(new_notes),'') end,
    next_follow_up_at=new_next_follow_up_at,updated_at=now()
  where p.id=target_prospect_id returning p.* into result_row;
  if previous_row.status is distinct from result_row.status then change_parts:=array_append(change_parts,'etapa'); end if;
  if previous_row.tag is distinct from result_row.tag then change_parts:=array_append(change_parts,'etiqueta'); end if;
  if previous_row.notes is distinct from result_row.notes then change_parts:=array_append(change_parts,'notas'); end if;
  if previous_row.next_follow_up_at is distinct from result_row.next_follow_up_at then change_parts:=array_append(change_parts,'seguimiento'); end if;
  if cardinality(change_parts)>0 then
    activity_summary:='Actualización: '||array_to_string(change_parts,', ');
    insert into public.prospect_activities(organization_id,prospect_id,actor_user_id,activity_type,summary,details)
    values(target_organization_id,target_prospect_id,(select auth.uid()),
      case when previous_row.status is distinct from result_row.status then 'status_change'
           when previous_row.next_follow_up_at is distinct from result_row.next_follow_up_at then 'follow_up'
           when previous_row.notes is distinct from result_row.notes then 'note' else 'update' end,
      activity_summary,
      jsonb_build_object('previous_status',previous_row.status,'status',result_row.status,'previous_tag',previous_row.tag,'tag',result_row.tag,
        'notes_changed',previous_row.notes is distinct from result_row.notes,'previous_next_follow_up_at',previous_row.next_follow_up_at,'next_follow_up_at',result_row.next_follow_up_at));
  end if;
  return jsonb_build_object('id',result_row.id,'status',result_row.status,'tag',result_row.tag,'notes',result_row.notes,'next_follow_up_at',result_row.next_follow_up_at,'updated_at',result_row.updated_at);
end;
$function$;
