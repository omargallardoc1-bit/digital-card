begin;

do $platform_customer_read_preflight$
begin
  if to_regclass('private.platform_admins') is null
     or to_regprocedure('private.platform_admin_role(uuid)') is null
     or to_regclass('public.organizations') is null
     or to_regclass('public.organization_subscriptions') is null
     or to_regclass('public.organization_subscription_card_limit_audit') is null
     or to_regclass('public.plans') is null
     or to_regclass('public.digital_cards') is null
  then
    raise exception 'Faltan dependencias para las RPC administrativas de clientes.';
  end if;
end;
$platform_customer_read_preflight$;

create or replace function public.list_platform_customers(
  actor_user_id uuid,
  search_text text,
  page integer,
  page_size integer
)
returns table(
  organization_id uuid,
  organization_name text,
  subscription_id uuid,
  plan_id uuid,
  plan_name text,
  subscription_status text,
  contracted_cards integer,
  used_cards bigint,
  available_cards bigint,
  over_limit_by bigint,
  is_over_limit boolean,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog'
as $function$
declare
  normalized_search text := nullif(btrim(coalesce(search_text, '')), '');
begin
  if private.platform_admin_role(actor_user_id) is distinct from 'superadmin' then
    raise exception using
      errcode = '42501',
      message = 'No tienes autorización de administración de plataforma.';
  end if;

  if page is null or page < 1 then
    raise exception using
      errcode = '22023',
      message = 'La página debe ser mayor o igual a 1.';
  end if;

  if page_size is null or page_size < 1 or page_size > 100 then
    raise exception using
      errcode = '22023',
      message = 'El tamaño de página debe estar entre 1 y 100.';
  end if;

  if normalized_search is not null and char_length(normalized_search) > 160 then
    raise exception using
      errcode = '22023',
      message = 'La búsqueda debe tener máximo 160 caracteres.';
  end if;

  if exists (
    select 1
    from public.organization_subscriptions as subscription
    join public.organizations as organization
      on organization.id = subscription.organization_id
    join public.plans as plan
      on plan.id = subscription.plan_id
    where organization.status = 'active'
      and subscription.status in ('trial', 'active', 'past_due')
      and subscription.starts_at <= now()
      and (subscription.expires_at is null or subscription.expires_at > now())
      and plan.status = 'active'
    group by subscription.organization_id
    having count(*) > 1
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'Se detectaron múltiples suscripciones efectivas para una organización.';
  end if;

  return query
  with effective_subscription as (
    select
      subscription.organization_id,
      subscription.id as subscription_id,
      subscription.plan_id,
      plan.name as plan_name,
      subscription.status as subscription_status,
      subscription.contracted_cards
    from public.organization_subscriptions as subscription
    join public.organizations as organization
      on organization.id = subscription.organization_id
    join public.plans as plan
      on plan.id = subscription.plan_id
    where organization.status = 'active'
      and subscription.status in ('trial', 'active', 'past_due')
      and subscription.starts_at <= now()
      and (subscription.expires_at is null or subscription.expires_at > now())
      and plan.status = 'active'
  ),
  customer_rows as (
    select
      organization.id as organization_id,
      organization.name as organization_name,
      effective.subscription_id,
      effective.plan_id,
      effective.plan_name,
      effective.subscription_status,
      effective.contracted_cards,
      card_usage.used_cards,
      case
        when effective.subscription_id is null then null::bigint
        else greatest(effective.contracted_cards::bigint - card_usage.used_cards, 0::bigint)
      end as available_cards,
      case
        when effective.subscription_id is null then null::bigint
        else greatest(card_usage.used_cards - effective.contracted_cards::bigint, 0::bigint)
      end as over_limit_by,
      case
        when effective.subscription_id is null then null::boolean
        else card_usage.used_cards > effective.contracted_cards::bigint
      end as is_over_limit
    from public.organizations as organization
    left join effective_subscription as effective
      on effective.organization_id = organization.id
    cross join lateral (
      select count(*)::bigint as used_cards
      from public.digital_cards as card
      where card.organization_id = organization.id
        and card.status in ('draft', 'published')
    ) as card_usage
    where normalized_search is null
       or organization.name ilike '%' || normalized_search || '%'
  )
  select
    customer.organization_id,
    customer.organization_name,
    customer.subscription_id,
    customer.plan_id,
    customer.plan_name,
    customer.subscription_status,
    customer.contracted_cards,
    customer.used_cards,
    customer.available_cards,
    customer.over_limit_by,
    customer.is_over_limit,
    count(*) over()::bigint as total_count
  from customer_rows as customer
  order by lower(customer.organization_name), customer.organization_id
  limit page_size
  offset ((page - 1)::bigint * page_size::bigint);
end;
$function$;

create or replace function public.get_platform_customer(
  actor_user_id uuid,
  target_organization_id uuid
)
returns table(
  organization_id uuid,
  organization_name text,
  subscription_id uuid,
  plan_id uuid,
  plan_name text,
  subscription_status text,
  starts_at timestamp with time zone,
  expires_at timestamp with time zone,
  contracted_cards integer,
  used_cards bigint,
  available_cards bigint,
  over_limit_by bigint,
  is_over_limit boolean
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog'
as $function$
declare
  effective_subscription_count integer;
begin
  if private.platform_admin_role(actor_user_id) is distinct from 'superadmin' then
    raise exception using
      errcode = '42501',
      message = 'No tienes autorización de administración de plataforma.';
  end if;

  if target_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'La organización es obligatoria.';
  end if;

  if not exists (
    select 1
    from public.organizations as organization
    where organization.id = target_organization_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'La organización no existe.';
  end if;

  select count(*)::integer
  into effective_subscription_count
  from public.organization_subscriptions as subscription
  join public.organizations as organization
    on organization.id = subscription.organization_id
  join public.plans as plan
    on plan.id = subscription.plan_id
  where subscription.organization_id = target_organization_id
    and organization.status = 'active'
    and subscription.status in ('trial', 'active', 'past_due')
    and subscription.starts_at <= now()
    and (subscription.expires_at is null or subscription.expires_at > now())
    and plan.status = 'active';

  if effective_subscription_count > 1 then
    raise exception using
      errcode = 'P0001',
      message = 'Se detectaron múltiples suscripciones efectivas para la organización.';
  end if;

  return query
  with effective_subscription as (
    select
      subscription.organization_id,
      subscription.id as subscription_id,
      subscription.plan_id,
      plan.name as plan_name,
      subscription.status as subscription_status,
      subscription.starts_at,
      subscription.expires_at,
      subscription.contracted_cards
    from public.organization_subscriptions as subscription
    join public.organizations as organization
      on organization.id = subscription.organization_id
    join public.plans as plan
      on plan.id = subscription.plan_id
    where subscription.organization_id = target_organization_id
      and organization.status = 'active'
      and subscription.status in ('trial', 'active', 'past_due')
      and subscription.starts_at <= now()
      and (subscription.expires_at is null or subscription.expires_at > now())
      and plan.status = 'active'
  )
  select
    organization.id,
    organization.name,
    effective.subscription_id,
    effective.plan_id,
    effective.plan_name,
    effective.subscription_status,
    effective.starts_at,
    effective.expires_at,
    effective.contracted_cards,
    card_usage.used_cards,
    case
      when effective.subscription_id is null then null::bigint
      else greatest(effective.contracted_cards::bigint - card_usage.used_cards, 0::bigint)
    end,
    case
      when effective.subscription_id is null then null::bigint
      else greatest(card_usage.used_cards - effective.contracted_cards::bigint, 0::bigint)
    end,
    case
      when effective.subscription_id is null then null::boolean
      else card_usage.used_cards > effective.contracted_cards::bigint
    end
  from public.organizations as organization
  left join effective_subscription as effective
    on effective.organization_id = organization.id
  cross join lateral (
    select count(*)::bigint as used_cards
    from public.digital_cards as card
    where card.organization_id = organization.id
      and card.status in ('draft', 'published')
  ) as card_usage
  where organization.id = target_organization_id;
end;
$function$;

create or replace function public.list_platform_card_limit_history(
  actor_user_id uuid,
  target_subscription_id uuid,
  page integer,
  page_size integer
)
returns table(
  changed_at timestamp with time zone,
  old_contracted_cards integer,
  new_contracted_cards integer,
  change_reason text,
  changed_by uuid,
  changed_by_display_name text,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog'
as $function$
begin
  if private.platform_admin_role(actor_user_id) is distinct from 'superadmin' then
    raise exception using
      errcode = '42501',
      message = 'No tienes autorización de administración de plataforma.';
  end if;

  if target_subscription_id is null then
    raise exception using
      errcode = '22023',
      message = 'La suscripción es obligatoria.';
  end if;

  if page is null or page < 1 then
    raise exception using
      errcode = '22023',
      message = 'La página debe ser mayor o igual a 1.';
  end if;

  if page_size is null or page_size < 1 or page_size > 100 then
    raise exception using
      errcode = '22023',
      message = 'El tamaño de página debe estar entre 1 y 100.';
  end if;

  if not exists (
    select 1
    from public.organization_subscriptions as subscription
    where subscription.id = target_subscription_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'La suscripción no existe.';
  end if;

  return query
  select
    audit.changed_at,
    audit.old_contracted_cards,
    audit.new_contracted_cards,
    audit.change_reason,
    audit.changed_by,
    administrator.display_name,
    count(*) over()::bigint as total_count
  from public.organization_subscription_card_limit_audit as audit
  left join private.platform_admins as administrator
    on administrator.user_id = audit.changed_by
  where audit.subscription_id = target_subscription_id
  order by audit.changed_at desc, audit.id desc
  limit page_size
  offset ((page - 1)::bigint * page_size::bigint);
end;
$function$;

revoke all on function public.list_platform_customers(uuid, text, integer, integer)
from public, anon, authenticated, service_role;

revoke all on function public.get_platform_customer(uuid, uuid)
from public, anon, authenticated, service_role;

revoke all on function public.list_platform_card_limit_history(uuid, uuid, integer, integer)
from public, anon, authenticated, service_role;

grant execute on function public.list_platform_customers(uuid, text, integer, integer)
to service_role;

grant execute on function public.get_platform_customer(uuid, uuid)
to service_role;

grant execute on function public.list_platform_card_limit_history(uuid, uuid, integer, integer)
to service_role;

do $platform_customer_read_postflight$
declare
  function_name text;
begin
  foreach function_name in array array[
    'public.list_platform_customers(uuid,text,integer,integer)',
    'public.get_platform_customer(uuid,uuid)',
    'public.list_platform_card_limit_history(uuid,uuid,integer,integer)'
  ]
  loop
    if to_regprocedure(function_name) is null
       or has_function_privilege('anon', function_name, 'EXECUTE')
       or has_function_privilege('authenticated', function_name, 'EXECUTE')
       or not has_function_privilege('service_role', function_name, 'EXECUTE')
       or exists (
         select 1
         from pg_catalog.pg_proc as procedure
         cross join lateral pg_catalog.aclexplode(
           coalesce(procedure.proacl, pg_catalog.acldefault('f', procedure.proowner))
         ) as privilege
         where procedure.oid = to_regprocedure(function_name)
           and privilege.grantee = 0
           and privilege.privilege_type = 'EXECUTE'
       )
    then
      raise exception 'Los grants de % no coinciden.', function_name;
    end if;
  end loop;

  if has_table_privilege('anon', 'private.platform_admins', 'SELECT')
     or has_table_privilege('authenticated', 'private.platform_admins', 'SELECT')
     or has_table_privilege('anon', 'public.organization_subscription_card_limit_audit', 'SELECT')
     or has_table_privilege('authenticated', 'public.organization_subscription_card_limit_audit', 'SELECT')
  then
    raise exception 'Se detectaron grants directos incompatibles con las RPC administrativas.';
  end if;
end;
$platform_customer_read_postflight$;

commit;
