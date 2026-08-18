begin;

alter table public.organization_subscriptions
  add column contracted_cards integer;

update public.organization_subscriptions as subscription
set contracted_cards = plan.max_cards
from public.plans as plan
where plan.id = subscription.plan_id;

do $contracted_cards_backfill$
begin
  if exists (
    select 1
    from public.organization_subscriptions as subscription
    where subscription.contracted_cards is null
  ) then
    raise exception
      'No se pudo determinar contracted_cards para todas las suscripciones.';
  end if;
end;
$contracted_cards_backfill$;

alter table public.organization_subscriptions
  add constraint organization_subscriptions_contracted_cards_check
  check (contracted_cards >= 0);

alter table public.organization_subscriptions
  alter column contracted_cards set not null;

comment on column public.organization_subscriptions.contracted_cards is
  'Cantidad de tarjetas contratada para esta suscripción. Debe proporcionarse explícitamente al crear una suscripción.';

create or replace function private.get_effective_plan(target_organization_id uuid)
 returns table(subscription_id uuid, subscription_status text, plan_id uuid, plan_code text, plan_name text, max_cards integer, max_members integer, lead_capture_enabled boolean, analytics_enabled boolean, analytics_history_days integer, qr_enabled boolean, profile_image_enabled boolean, logo_image_enabled boolean, cover_image_enabled boolean, csv_export_enabled boolean, video_enabled boolean)
 language sql
 stable security definer
 set search_path to 'pg_catalog'
as $function$
  select
    subscription.id,
    subscription.status,
    plan.id,
    plan.code,
    plan.name,
    subscription.contracted_cards,
    plan.max_members,
    plan.lead_capture_enabled,
    plan.analytics_enabled,
    plan.analytics_history_days,
    plan.qr_enabled,
    plan.profile_image_enabled,
    plan.logo_image_enabled,
    plan.cover_image_enabled,
    plan.csv_export_enabled,
    plan.video_enabled
  from public.organizations as organization
  join public.organization_subscriptions as subscription
    on subscription.organization_id = organization.id
  join public.plans as plan
    on plan.id = subscription.plan_id
  where organization.id = target_organization_id
    and organization.status = 'active'
    and subscription.status in ('trial', 'active', 'past_due')
    and subscription.starts_at <= now()
    and (
      subscription.expires_at is null
      or subscription.expires_at > now()
    )
    and plan.status = 'active'
  limit 1;
$function$;

create or replace function public.get_organization_card_capacity(target_organization_id uuid)
 returns table(subscription_id uuid, plan_id uuid, plan_name text, subscription_status text, contracted_cards integer, used_cards bigint, available_cards bigint, over_limit_by bigint, is_over_limit boolean)
 language plpgsql
 stable security definer
 set search_path to 'pg_catalog'
as $function$
declare
  current_user_id uuid := auth.uid();
  effective_plan record;
  current_used_cards bigint;
begin
  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  if target_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'La organización es obligatoria.';
  end if;

  if not exists (
    select 1
    from public.organization_members as member
    where member.organization_id = target_organization_id
      and member.user_id = current_user_id
      and member.status = 'active'
  ) then
    raise exception using
      errcode = '42501',
      message = 'No tienes acceso a esta organización.';
  end if;

  select *
  into effective_plan
  from private.get_effective_plan(target_organization_id);

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'La organización no tiene una suscripción utilizable.';
  end if;

  select count(*)
  into current_used_cards
  from public.digital_cards as card
  where card.organization_id = target_organization_id
    and card.status in ('draft', 'published');

  return query
  select
    effective_plan.subscription_id::uuid,
    effective_plan.plan_id::uuid,
    effective_plan.plan_name::text,
    effective_plan.subscription_status::text,
    effective_plan.max_cards::integer,
    current_used_cards,
    greatest(effective_plan.max_cards::bigint - current_used_cards, 0::bigint),
    greatest(current_used_cards - effective_plan.max_cards::bigint, 0::bigint),
    current_used_cards > effective_plan.max_cards::bigint;
end;
$function$;

revoke all on function public.get_organization_card_capacity(uuid)
from public, anon, authenticated, service_role;

grant execute on function public.get_organization_card_capacity(uuid)
to authenticated;

do $contracted_cards_postflight$
begin
  if exists (
    select 1
    from public.organization_subscriptions as subscription
    join public.plans as plan
      on plan.id = subscription.plan_id
    where subscription.contracted_cards is distinct from plan.max_cards
  ) then
    raise exception
      'El backfill de contracted_cards no preservó la capacidad anterior.';
  end if;

  if to_regprocedure('private.get_effective_plan(uuid)') is null
     or to_regprocedure('public.get_organization_card_capacity(uuid)') is null
  then
    raise exception 'Faltan funciones requeridas para contracted_cards.';
  end if;

  if has_function_privilege('anon', 'public.get_organization_card_capacity(uuid)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.get_organization_card_capacity(uuid)', 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           procedure.proacl,
           pg_catalog.acldefault('f', procedure.proowner)
         )
       ) as privilege
       where procedure.oid = 'public.get_organization_card_capacity(uuid)'::regprocedure
         and privilege.grantee = 0
         and privilege.privilege_type = 'EXECUTE'
     )
  then
    raise exception 'Los grants de get_organization_card_capacity(uuid) no coinciden.';
  end if;
end;
$contracted_cards_postflight$;

commit;
