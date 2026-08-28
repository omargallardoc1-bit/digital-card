begin;

create or replace function public.create_organization_appointment_block_local(
  target_organization_id uuid,
  target_card_id uuid,
  local_starts_at timestamp,
  local_ends_at timestamp,
  block_timezone text,
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
  normalized_timezone text:=btrim(coalesce(block_timezone,''));
  starts_tz timestamptz;
  ends_tz timestamptz;
begin
  if normalized_timezone='' or not exists(select 1 from pg_catalog.pg_timezone_names where name=normalized_timezone) then
    raise exception using errcode='22023', message='La zona horaria no es válida.';
  end if;
  if local_starts_at is null or local_ends_at is null or local_starts_at>=local_ends_at then
    raise exception using errcode='22023', message='El rango de bloqueo no es válido.';
  end if;
  starts_tz := local_starts_at at time zone normalized_timezone;
  ends_tz := local_ends_at at time zone normalized_timezone;
  return public.create_organization_appointment_block(target_organization_id,target_card_id,starts_tz,ends_tz,block_source,block_note,target_branch_id);
end;
$function$;

revoke all on function public.create_organization_appointment_block_local(uuid,uuid,timestamp,timestamp,text,text,text,uuid) from public;
grant execute on function public.create_organization_appointment_block_local(uuid,uuid,timestamp,timestamp,text,text,text,uuid) to authenticated,service_role;

commit;
