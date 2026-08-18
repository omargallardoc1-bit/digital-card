begin;

do $platform_admin_identity_preflight$
begin
  if to_regnamespace('private') is null
     or to_regprocedure('private.set_updated_at()') is null
  then
    raise exception
      'La identidad administrativa requiere el schema private y private.set_updated_at().';
  end if;

  if to_regclass('private.platform_admins') is not null
     or to_regprocedure('private.platform_admin_role(uuid)') is not null
     or to_regprocedure('public.bootstrap_platform_superadmin(uuid,text)') is not null
  then
    raise exception
      'La identidad administrativa interna ya existe total o parcialmente.';
  end if;
end;
$platform_admin_identity_preflight$;

create table private.platform_admins (
  user_id uuid not null,
  role text not null,
  status text default 'active'::text not null,
  display_name text,
  created_at timestamp with time zone default statement_timestamp() not null,
  updated_at timestamp with time zone default statement_timestamp() not null,
  created_by uuid,
  disabled_at timestamp with time zone,
  disabled_by uuid,
  constraint platform_admins_pkey primary key (user_id),
  constraint platform_admins_user_id_fkey
    foreign key (user_id) references auth.users(id) on delete cascade,
  constraint platform_admins_created_by_fkey
    foreign key (created_by) references auth.users(id) on delete set null,
  constraint platform_admins_disabled_by_fkey
    foreign key (disabled_by) references auth.users(id) on delete set null,
  constraint platform_admins_role_check
    check (role in ('superadmin', 'commercial', 'support')),
  constraint platform_admins_status_check
    check (status in ('active', 'disabled')),
  constraint platform_admins_display_name_check
    check (display_name is null or nullif(btrim(display_name), '') is not null),
  constraint platform_admins_disabled_state_check
    check (
      (status = 'active' and disabled_at is null and disabled_by is null)
      or (status = 'disabled' and disabled_at is not null)
    ),
  constraint platform_admins_timestamps_check
    check (updated_at >= created_at)
);

comment on table private.platform_admins is
  'Identidades administrativas internas de MX Business Card, independientes de las membresías de organizaciones cliente.';

comment on column private.platform_admins.created_by is
  'Actor interno que creó el registro. NULL durante el bootstrap inicial ejecutado por service_role.';

create trigger platform_admins_set_updated_at
before update on private.platform_admins
for each row
execute function private.set_updated_at();

alter table private.platform_admins enable row level security;

revoke all privileges
on table private.platform_admins
from public, anon, authenticated, service_role;

create or replace function private.platform_admin_role(target_user_id uuid)
 returns text
 language sql
 stable
 security definer
 set search_path to 'pg_catalog'
as $function$
  select platform_admin.role
  from private.platform_admins as platform_admin
  where platform_admin.user_id = target_user_id
    and platform_admin.status = 'active'
  limit 1
$function$;

create or replace function public.bootstrap_platform_superadmin(
  target_user_id uuid,
  target_display_name text default null
)
 returns table(
   user_id uuid,
   role text,
   status text,
   display_name text,
   created_at timestamp with time zone
 )
 language plpgsql
 security definer
 set search_path to 'pg_catalog'
as $function$
declare
  normalized_display_name text := nullif(btrim(coalesce(target_display_name, '')), '');
begin
  if target_user_id is null then
    raise exception using
      errcode = '22023',
      message = 'El usuario Auth es obligatorio.';
  end if;

  if not exists (
    select 1
    from auth.users as auth_user
    where auth_user.id = target_user_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'El usuario Auth no existe.';
  end if;

  if exists (
    select 1
    from private.platform_admins
  ) then
    raise exception using
      errcode = '55000',
      message = 'El bootstrap inicial de administración ya fue completado.';
  end if;

  return query
  insert into private.platform_admins as platform_admin (
    user_id,
    role,
    status,
    display_name,
    created_by
  )
  values (
    target_user_id,
    'superadmin',
    'active',
    normalized_display_name,
    null
  )
  returning
    platform_admin.user_id,
    platform_admin.role,
    platform_admin.status,
    platform_admin.display_name,
    platform_admin.created_at;
end;
$function$;

revoke all on function private.platform_admin_role(uuid)
from public, anon, authenticated, service_role;

revoke all on function public.bootstrap_platform_superadmin(uuid, text)
from public, anon, authenticated, service_role;

grant execute on function public.bootstrap_platform_superadmin(uuid, text)
to service_role;

do $platform_admin_identity_postflight$
begin
  if not exists (
    select 1
    from pg_catalog.pg_class as relation
    join pg_catalog.pg_namespace as namespace
      on namespace.oid = relation.relnamespace
    where namespace.nspname = 'private'
      and relation.relname = 'platform_admins'
      and relation.relkind = 'r'
      and relation.relrowsecurity
  ) then
    raise exception
      'private.platform_admins no existe o no tiene RLS habilitado.';
  end if;

  if has_table_privilege('anon', 'private.platform_admins', 'SELECT')
     or has_table_privilege('authenticated', 'private.platform_admins', 'SELECT')
     or has_table_privilege('service_role', 'private.platform_admins', 'SELECT')
     or has_table_privilege('anon', 'private.platform_admins', 'INSERT')
     or has_table_privilege('authenticated', 'private.platform_admins', 'INSERT')
     or has_table_privilege('service_role', 'private.platform_admins', 'INSERT')
     or has_table_privilege('anon', 'private.platform_admins', 'UPDATE')
     or has_table_privilege('authenticated', 'private.platform_admins', 'UPDATE')
     or has_table_privilege('service_role', 'private.platform_admins', 'UPDATE')
     or has_table_privilege('anon', 'private.platform_admins', 'DELETE')
     or has_table_privilege('authenticated', 'private.platform_admins', 'DELETE')
     or has_table_privilege('service_role', 'private.platform_admins', 'DELETE')
  then
    raise exception
      'Los grants directos de private.platform_admins no coinciden.';
  end if;

  if has_function_privilege('anon', 'private.platform_admin_role(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated', 'private.platform_admin_role(uuid)', 'EXECUTE')
     or has_function_privilege('service_role', 'private.platform_admin_role(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.bootstrap_platform_superadmin(uuid,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.bootstrap_platform_superadmin(uuid,text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.bootstrap_platform_superadmin(uuid,text)', 'EXECUTE')
  then
    raise exception
      'Los grants de identidad administrativa no coinciden.';
  end if;

  if exists (select 1 from private.platform_admins) then
    raise exception
      'La migración no debe crear automáticamente administradores de plataforma.';
  end if;
end;
$platform_admin_identity_postflight$;

commit;
