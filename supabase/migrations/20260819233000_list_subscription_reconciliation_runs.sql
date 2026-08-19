create or replace function public.list_subscription_reconciliation_runs(
  actor_user_id uuid,
  page integer default 1,
  page_size integer default 25
)
returns table(
  id uuid,
  as_of timestamptz,
  mode text,
  started_at timestamptz,
  actor_kind text,
  changed_count integer,
  skipped_count integer
)
language plpgsql
stable
security definer
set search_path=pg_catalog
as $$
begin
  if private.platform_admin_role(actor_user_id) is distinct from 'superadmin' then
    raise exception using errcode='42501',message='No tienes autorización de administración de plataforma.';
  end if;
  if page<1 or page_size<1 or page_size>100 then
    raise exception using errcode='22023',message='La paginación no es válida.';
  end if;
  return query
  select r.id,r.as_of,r.mode,r.started_at,r.actor_kind,r.changed_count,r.skipped_count
  from public.subscription_reconciliation_runs r
  order by r.started_at desc,r.id desc
  limit page_size offset ((page-1)*page_size);
end;
$$;
revoke all on function public.list_subscription_reconciliation_runs(uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.list_subscription_reconciliation_runs(uuid,integer,integer) to service_role;