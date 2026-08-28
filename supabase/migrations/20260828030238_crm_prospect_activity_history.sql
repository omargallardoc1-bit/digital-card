create table if not exists public.prospect_activities (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  prospect_id uuid not null references public.prospects(id) on delete cascade,
  actor_user_id uuid,
  activity_type text not null check (activity_type in ('created','update','status_change','follow_up','note','manual')),
  summary text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
alter table public.prospect_activities enable row level security;
revoke all on table public.prospect_activities from public, anon, authenticated;
create index if not exists prospect_activities_prospect_created_idx on public.prospect_activities(prospect_id, created_at desc);
create index if not exists prospect_activities_org_created_idx on public.prospect_activities(organization_id, created_at desc);

create or replace function public.list_organization_prospect_activities(target_organization_id uuid,target_prospect_id uuid,requested_limit integer default 100)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog' as $function$
declare safe_limit integer; result jsonb;
begin
  if (select auth.uid()) is null then raise exception using errcode='42501', message='Se requiere autenticación.'; end if;
  if target_organization_id is null or not exists (select 1 from public.organization_members m where m.organization_id=target_organization_id and m.user_id=(select auth.uid()) and m.status='active' and m.role in ('owner','admin','editor')) then raise exception using errcode='42501', message='No tienes permiso para consultar el historial.'; end if;
  if not exists (select 1 from public.prospects p join public.digital_cards c on c.id=p.card_id where p.id=target_prospect_id and c.organization_id=target_organization_id) then raise exception using errcode='22023', message='El prospecto no pertenece a la organización.'; end if;
  safe_limit:=least(greatest(coalesce(requested_limit,100),1),200);
  select coalesce(jsonb_agg(x.item order by x.created_at desc),'[]'::jsonb) into result from (
    select a.created_at,jsonb_build_object('id',a.id,'activity_type',a.activity_type,'summary',a.summary,'details',a.details,'actor_user_id',a.actor_user_id,'created_at',a.created_at) item
    from public.prospect_activities a where a.organization_id=target_organization_id and a.prospect_id=target_prospect_id order by a.created_at desc limit safe_limit
  ) x;
  return result;
end;$function$;
revoke all on function public.list_organization_prospect_activities(uuid,uuid,integer) from public, anon;
grant execute on function public.list_organization_prospect_activities(uuid,uuid,integer) to authenticated;

create or replace function public.update_organization_prospect(target_organization_id uuid,target_prospect_id uuid,new_status text default null,new_tag text default null,new_notes text default null,new_next_follow_up_at timestamptz default null)
returns jsonb language plpgsql security definer set search_path to 'pg_catalog' as $function$
declare result_row public.prospects%rowtype; previous_row public.prospects%rowtype; normalized_status text; normalized_tag text; change_parts text[]:=array[]::text[]; activity_summary text;
begin
  if (select auth.uid()) is null then raise exception using errcode='42501', message='Se requiere autenticación.'; end if;
  if target_organization_id is null or not exists (select 1 from public.organization_members m where m.organization_id=target_organization_id and m.user_id=(select auth.uid()) and m.status='active' and m.role in ('owner','admin','editor')) then raise exception using errcode='42501', message='No tienes permiso para administrar prospectos.'; end if;
  select p.* into previous_row from public.prospects p join public.digital_cards c on c.id=p.card_id where p.id=target_prospect_id and c.organization_id=target_organization_id;
  if not found then raise exception using errcode='22023', message='El prospecto no pertenece a la organización.'; end if;
  normalized_status:=coalesce(new_status,previous_row.status); normalized_tag:=case when new_tag is null then previous_row.tag else nullif(btrim(new_tag),'') end;
  if normalized_status not in ('new','contacted','follow_up','customer','discarded') then raise exception using errcode='22023', message='El estado no es válido.'; end if;
  if normalized_tag is not null and normalized_tag not in ('prospect','customer','supplier','alliance','other') then raise exception using errcode='22023', message='La etiqueta no es válida.'; end if;
  update public.prospects p set status=normalized_status,tag=normalized_tag,notes=case when new_notes is null then p.notes else nullif(btrim(new_notes),'') end,next_follow_up_at=new_next_follow_up_at,updated_at=now() where p.id=target_prospect_id returning p.* into result_row;
  if previous_row.status is distinct from result_row.status then change_parts:=array_append(change_parts,'etapa'); end if;
  if previous_row.tag is distinct from result_row.tag then change_parts:=array_append(change_parts,'etiqueta'); end if;
  if previous_row.notes is distinct from result_row.notes then change_parts:=array_append(change_parts,'notas'); end if;
  if previous_row.next_follow_up_at is distinct from result_row.next_follow_up_at then change_parts:=array_append(change_parts,'seguimiento'); end if;
  if cardinality(change_parts)>0 then
    activity_summary:='Actualización: '||array_to_string(change_parts,', ');
    insert into public.prospect_activities(organization_id,prospect_id,actor_user_id,activity_type,summary,details) values(target_organization_id,target_prospect_id,(select auth.uid()),case when previous_row.status is distinct from result_row.status then 'status_change' when previous_row.next_follow_up_at is distinct from result_row.next_follow_up_at then 'follow_up' when previous_row.notes is distinct from result_row.notes then 'note' else 'update' end,activity_summary,jsonb_build_object('previous_status',previous_row.status,'status',result_row.status,'previous_tag',previous_row.tag,'tag',result_row.tag,'notes_changed',previous_row.notes is distinct from result_row.notes,'previous_next_follow_up_at',previous_row.next_follow_up_at,'next_follow_up_at',result_row.next_follow_up_at));
  end if;
  return jsonb_build_object('id',result_row.id,'status',result_row.status,'tag',result_row.tag,'notes',result_row.notes,'next_follow_up_at',result_row.next_follow_up_at,'updated_at',result_row.updated_at);
end;$function$;
revoke all on function public.update_organization_prospect(uuid,uuid,text,text,text,timestamptz) from public, anon;
grant execute on function public.update_organization_prospect(uuid,uuid,text,text,text,timestamptz) to authenticated;