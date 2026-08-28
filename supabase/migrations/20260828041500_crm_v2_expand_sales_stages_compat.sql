alter table public.prospects drop constraint if exists prospects_status_check;
alter table public.prospects add constraint prospects_status_check check (status in ('new','contacted','follow_up','customer','discarded','interested','appointment','proposal','won','lost'));

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
    where m.organization_id=target_organization_id and m.user_id=auth.uid() and m.status='active' and m.role in ('owner','admin','editor')
  ) then raise exception using errcode='42501', message='No tienes permiso para consultar el embudo comercial.'; end if;
  if target_card_id is not null and not exists (
    select 1 from public.digital_cards c where c.id=target_card_id and c.organization_id=target_organization_id
  ) then raise exception using errcode='22023', message='La tarjeta no pertenece a la organización.'; end if;
  select jsonb_build_object(
    'prospects',count(*),'new',count(*) filter(where p.status='new'),'contacted',count(*) filter(where p.status='contacted'),
    'interested',count(*) filter(where p.status='interested'),'appointment',count(*) filter(where p.status='appointment'),
    'proposal',count(*) filter(where p.status='proposal'),'won',count(*) filter(where p.status='won'),'lost',count(*) filter(where p.status='lost'),
    'follow_up',count(*) filter(where p.status='follow_up'),'customers',count(*) filter(where p.status='customer'),'discarded',count(*) filter(where p.status='discarded'),
    'worked',count(*) filter(where p.status in ('contacted','interested','appointment','proposal','won','follow_up','customer')),
    'prospect_to_customer_rate',case when count(*)=0 then 0 else round((count(*) filter(where p.status in ('won','customer')))::numeric*100/count(*),1) end
  ) into result
  from public.prospects p join public.digital_cards c on c.id=p.card_id
  where c.organization_id=target_organization_id and (target_card_id is null or c.id=target_card_id);
  return result;
end;
$function$;

create or replace function public.update_organization_prospect(target_organization_id uuid, target_prospect_id uuid, new_status text default null::text, new_tag text default null::text, new_notes text default null::text, new_next_follow_up_at timestamptz default null::timestamptz)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  result_row public.prospects%rowtype; previous_row public.prospects%rowtype; normalized_status text; normalized_tag text;
  change_parts text[]:=array[]::text[]; activity_summary text;
begin
  if (select auth.uid()) is null then raise exception using errcode='42501',message='Se requiere autenticación.'; end if;
  if target_organization_id is null or not exists (
    select 1 from public.organization_members m where m.organization_id=target_organization_id and m.user_id=(select auth.uid()) and m.status='active' and m.role in ('owner','admin','editor')
  ) then raise exception using errcode='42501',message='No tienes permiso para administrar prospectos.'; end if;
  select p.* into previous_row from public.prospects p join public.digital_cards c on c.id=p.card_id
  where p.id=target_prospect_id and c.organization_id=target_organization_id;
  if not found then raise exception using errcode='22023',message='El prospecto no pertenece a la organización.'; end if;
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