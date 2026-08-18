begin;

do $platform_admin_setter_preflight$
begin
  if to_regclass('private.platform_admins') is null
     or to_regprocedure('private.platform_admin_role(uuid)') is null
     or to_regclass('public.organizations') is null
     or to_regclass('public.organization_subscriptions') is null
     or to_regclass('public.organization_subscription_card_limit_audit') is null
     or to_regclass('public.plans') is null
     or to_regclass('public.digital_cards') is null
     or to_regprocedure('public.set_subscription_contracted_cards(uuid,integer,text)') is null
  then
    raise exception 'Faltan dependencias para el setter administrativo de tarjetas contratadas.';
  end if;
end;
$platform_admin_setter_preflight$;

create or replace function public.set_subscription_contracted_cards_by_admin(
  actor_user_id uuid,
  target_subscription_id uuid,
  expected_contracted_cards integer,
  new_contracted_cards integer,
  change_reason text
)
returns table(
  subscription_id uuid,
  organization_id uuid,
  old_contracted_cards integer,
  contracted_cards integer,
  used_cards bigint,
  available_cards bigint,
  over_limit_by bigint,
  is_over_limit boolean,
  changed_by uuid
)
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  initial_organization_id uuid;
  locked_organization_id uuid;
  locked_subscription public.organization_subscriptions%rowtype;
  locked_plan_id uuid;
  normalized_reason text;
  previous_contracted_cards integer;
  current_used_cards bigint;
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

  if expected_contracted_cards is null or expected_contracted_cards < 0 then
    raise exception using
      errcode = '22023',
      message = 'La cantidad esperada debe ser mayor o igual a cero.';
  end if;

  if new_contracted_cards is null or new_contracted_cards < 0 then
    raise exception using
      errcode = '22023',
      message = 'La cantidad contratada debe ser mayor o igual a cero.';
  end if;

  normalized_reason := btrim(coalesce(change_reason, ''));

  if normalized_reason = '' or char_length(normalized_reason) > 500 then
    raise exception using
      errcode = '22023',
      message = 'El motivo es obligatorio y debe tener máximo 500 caracteres.';
  end if;

  select subscription.organization_id
  into initial_organization_id
  from public.organization_subscriptions as subscription
  where subscription.id = target_subscription_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La suscripción no existe.';
  end if;

  select organization.id
  into locked_organization_id
  from public.organizations as organization
  where organization.id = initial_organization_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La organización no existe.';
  end if;

  select subscription.*
  into locked_subscription
  from public.organization_subscriptions as subscription
  where subscription.id = target_subscription_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La suscripción no existe.';
  end if;

  if locked_subscription.organization_id is distinct from locked_organization_id then
    raise exception using
      errcode = '40001',
      message = 'La organización de la suscripción cambió durante la operación. Intenta nuevamente.';
  end if;

  select plan.id
  into locked_plan_id
  from public.plans as plan
  where plan.id = locked_subscription.plan_id
  for share;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'El plan de la suscripción no existe.';
  end if;

  previous_contracted_cards := locked_subscription.contracted_cards;

  if previous_contracted_cards is distinct from expected_contracted_cards then
    raise exception using
      errcode = '40001',
      message = 'La cantidad contratada cambió desde la última lectura. Actualiza los datos e intenta nuevamente.';
  end if;

  select count(*)
  into current_used_cards
  from public.digital_cards as card
  where card.organization_id = locked_organization_id
    and card.status in ('draft', 'published');

  update public.organization_subscriptions as subscription
  set contracted_cards = new_contracted_cards
  where subscription.id = locked_subscription.id;

  insert into public.organization_subscription_card_limit_audit (
    organization_id,
    subscription_id,
    old_contracted_cards,
    new_contracted_cards,
    change_reason,
    changed_at,
    changed_by
  )
  values (
    locked_organization_id,
    locked_subscription.id,
    previous_contracted_cards,
    new_contracted_cards,
    normalized_reason,
    statement_timestamp(),
    actor_user_id
  );

  return query
  select
    locked_subscription.id,
    locked_organization_id,
    previous_contracted_cards,
    new_contracted_cards,
    current_used_cards,
    greatest(new_contracted_cards::bigint - current_used_cards, 0::bigint),
    greatest(current_used_cards - new_contracted_cards::bigint, 0::bigint),
    current_used_cards > new_contracted_cards::bigint,
    actor_user_id;
end;
$function$;

revoke all on function public.set_subscription_contracted_cards_by_admin(
  uuid, uuid, integer, integer, text
)
from public, anon, authenticated, service_role;

grant execute on function public.set_subscription_contracted_cards_by_admin(
  uuid, uuid, integer, integer, text
)
to service_role;

do $platform_admin_setter_postflight$
begin
  if to_regprocedure(
    'public.set_subscription_contracted_cards_by_admin(uuid,uuid,integer,integer,text)'
  ) is null
     or has_function_privilege(
       'anon',
       'public.set_subscription_contracted_cards_by_admin(uuid,uuid,integer,integer,text)',
       'EXECUTE'
     )
     or has_function_privilege(
       'authenticated',
       'public.set_subscription_contracted_cards_by_admin(uuid,uuid,integer,integer,text)',
       'EXECUTE'
     )
     or not has_function_privilege(
       'service_role',
       'public.set_subscription_contracted_cards_by_admin(uuid,uuid,integer,integer,text)',
       'EXECUTE'
     )
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(
         coalesce(procedure.proacl, pg_catalog.acldefault('f', procedure.proowner))
       ) as privilege
       where procedure.oid =
         'public.set_subscription_contracted_cards_by_admin(uuid,uuid,integer,integer,text)'::regprocedure
         and privilege.grantee = 0
         and privilege.privilege_type = 'EXECUTE'
     )
  then
    raise exception 'Los grants del setter administrativo no coinciden.';
  end if;

  if to_regprocedure('public.set_subscription_contracted_cards(uuid,integer,text)') is null
     or not has_function_privilege(
       'service_role',
       'public.set_subscription_contracted_cards(uuid,integer,text)',
       'EXECUTE'
     )
  then
    raise exception 'El setter técnico existente no debe modificarse.';
  end if;
end;
$platform_admin_setter_postflight$;

commit;
