begin;

do $contracted_cards_admin_preflight$
begin
  if not exists (
    select 1
    from pg_catalog.pg_attribute as attribute
    where attribute.attrelid = 'public.organization_subscriptions'::regclass
      and attribute.attname = 'contracted_cards'
      and not attribute.attisdropped
      and attribute.attnotnull
  ) then
    raise exception
      'La migración 8B-2B debe instalarse antes del control administrativo.';
  end if;

  if to_regprocedure('public.get_organization_card_capacity(uuid)') is null then
    raise exception
      'Falta get_organization_card_capacity(uuid) de la migración 8B-2B.';
  end if;
end;
$contracted_cards_admin_preflight$;

create table public.organization_subscription_card_limit_audit (
  id uuid default gen_random_uuid() not null,
  organization_id uuid not null,
  subscription_id uuid not null,
  old_contracted_cards integer not null,
  new_contracted_cards integer not null,
  change_reason text not null,
  changed_at timestamp with time zone default statement_timestamp() not null,
  changed_by uuid,
  constraint organization_subscription_card_limit_audit_pkey primary key (id),
  constraint organization_subscription_card_limit_audit_organization_id_fkey
    foreign key (organization_id) references public.organizations(id) on delete restrict,
  constraint organization_subscription_card_limit_audit_subscription_id_fkey
    foreign key (subscription_id) references public.organization_subscriptions(id) on delete restrict,
  constraint organization_subscription_card_limit_audit_changed_by_fkey
    foreign key (changed_by) references auth.users(id) on delete set null,
  constraint organization_subscription_card_limit_audit_old_value_check
    check (old_contracted_cards >= 0),
  constraint organization_subscription_card_limit_audit_new_value_check
    check (new_contracted_cards >= 0),
  constraint organization_subscription_card_limit_audit_reason_check
    check (
      nullif(btrim(change_reason), '') is not null
      and char_length(change_reason) <= 500
    )
);

comment on table public.organization_subscription_card_limit_audit is
  'Auditoría append-only de cambios en la cantidad de tarjetas contratadas.';

comment on column public.organization_subscription_card_limit_audit.changed_by is
  'NULL hasta que una futura Edge Function administrativa pueda registrar un actor autenticado confiable.';

create index organization_subscription_card_limit_audit_subscription_changed_idx
on public.organization_subscription_card_limit_audit (subscription_id, changed_at desc);

create index organization_subscription_card_limit_audit_organization_changed_idx
on public.organization_subscription_card_limit_audit (organization_id, changed_at desc);

create or replace function private.prevent_subscription_card_limit_audit_mutation()
 returns trigger
 language plpgsql
 set search_path to 'pg_catalog'
as $function$
begin
  raise exception using
    errcode = '55000',
    message = 'La auditoría de tarjetas contratadas es append-only.';
end;
$function$;

create trigger organization_subscription_card_limit_audit_append_only
before update or delete
on public.organization_subscription_card_limit_audit
for each row
execute function private.prevent_subscription_card_limit_audit_mutation();

alter table public.organization_subscription_card_limit_audit enable row level security;

revoke all privileges
on table public.organization_subscription_card_limit_audit
from public, anon, authenticated, service_role;

create or replace function public.set_subscription_contracted_cards(
  target_subscription_id uuid,
  new_contracted_cards integer,
  change_reason text
)
 returns table(
   audit_id uuid,
   organization_id uuid,
   subscription_id uuid,
   plan_id uuid,
   plan_name text,
   subscription_status text,
   old_contracted_cards integer,
   contracted_cards integer,
   used_cards bigint,
   available_cards bigint,
   over_limit_by bigint,
   is_over_limit boolean,
   changed_at timestamp with time zone
 )
 language plpgsql
 security definer
 set search_path to 'pg_catalog'
as $function$
declare
  initial_organization_id uuid;
  locked_organization_id uuid;
  locked_subscription public.organization_subscriptions%rowtype;
  locked_plan_name text;
  normalized_reason text;
  previous_contracted_cards integer;
  current_used_cards bigint;
  created_audit_id uuid;
  audit_timestamp timestamp with time zone := statement_timestamp();
begin
  if target_subscription_id is null then
    raise exception using
      errcode = '22023',
      message = 'La suscripción es obligatoria.';
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

  select plan.name
  into locked_plan_name
  from public.plans as plan
  where plan.id = locked_subscription.plan_id
  for share;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'El plan de la suscripción no existe.';
  end if;

  previous_contracted_cards := locked_subscription.contracted_cards;

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
    audit_timestamp,
    null
  )
  returning id into created_audit_id;

  return query
  select
    created_audit_id,
    locked_organization_id,
    locked_subscription.id,
    locked_subscription.plan_id,
    locked_plan_name,
    locked_subscription.status,
    previous_contracted_cards,
    new_contracted_cards,
    current_used_cards,
    greatest(new_contracted_cards::bigint - current_used_cards, 0::bigint),
    greatest(current_used_cards - new_contracted_cards::bigint, 0::bigint),
    current_used_cards > new_contracted_cards::bigint,
    audit_timestamp;
end;
$function$;

revoke all on function private.prevent_subscription_card_limit_audit_mutation()
from public, anon, authenticated, service_role;

revoke all on function public.set_subscription_contracted_cards(uuid, integer, text)
from public, anon, authenticated, service_role;

grant execute on function public.set_subscription_contracted_cards(uuid, integer, text)
to service_role;

do $contracted_cards_admin_postflight$
begin
  if not exists (
    select 1
    from pg_catalog.pg_class as relation
    where relation.oid = 'public.organization_subscription_card_limit_audit'::regclass
      and relation.relrowsecurity
  ) then
    raise exception 'RLS no está habilitado en la auditoría de tarjetas contratadas.';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_policies as policy
    where policy.schemaname = 'public'
      and policy.tablename = 'organization_subscription_card_limit_audit'
  ) then
    raise exception 'La auditoría no debe exponer policies directas.';
  end if;

  if has_table_privilege('anon', 'public.organization_subscription_card_limit_audit', 'SELECT')
     or has_table_privilege('anon', 'public.organization_subscription_card_limit_audit', 'INSERT')
     or has_table_privilege('anon', 'public.organization_subscription_card_limit_audit', 'UPDATE')
     or has_table_privilege('anon', 'public.organization_subscription_card_limit_audit', 'DELETE')
     or has_table_privilege('authenticated', 'public.organization_subscription_card_limit_audit', 'SELECT')
     or has_table_privilege('authenticated', 'public.organization_subscription_card_limit_audit', 'INSERT')
     or has_table_privilege('authenticated', 'public.organization_subscription_card_limit_audit', 'UPDATE')
     or has_table_privilege('authenticated', 'public.organization_subscription_card_limit_audit', 'DELETE')
     or has_table_privilege('service_role', 'public.organization_subscription_card_limit_audit', 'INSERT')
     or has_table_privilege('service_role', 'public.organization_subscription_card_limit_audit', 'UPDATE')
     or has_table_privilege('service_role', 'public.organization_subscription_card_limit_audit', 'DELETE')
     or has_column_privilege('anon', 'public.organization_subscriptions', 'contracted_cards', 'UPDATE')
     or has_column_privilege('authenticated', 'public.organization_subscriptions', 'contracted_cards', 'UPDATE')
     or has_column_privilege('service_role', 'public.organization_subscriptions', 'contracted_cards', 'UPDATE')
  then
    raise exception 'Los privilegios de tarjetas contratadas no coinciden.';
  end if;

  if has_function_privilege('anon', 'public.set_subscription_contracted_cards(uuid,integer,text)', 'EXECUTE')
     or has_function_privilege('authenticated', 'public.set_subscription_contracted_cards(uuid,integer,text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.set_subscription_contracted_cards(uuid,integer,text)', 'EXECUTE')
     or exists (
       select 1
       from pg_catalog.pg_proc as procedure
       cross join lateral pg_catalog.aclexplode(
         coalesce(
           procedure.proacl,
           pg_catalog.acldefault('f', procedure.proowner)
         )
       ) as privilege
       where procedure.oid = 'public.set_subscription_contracted_cards(uuid,integer,text)'::regprocedure
         and privilege.grantee = 0
         and privilege.privilege_type = 'EXECUTE'
     )
  then
    raise exception 'Los grants de set_subscription_contracted_cards no coinciden.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_trigger as trigger
    where trigger.tgrelid = 'public.organization_subscription_card_limit_audit'::regclass
      and trigger.tgname = 'organization_subscription_card_limit_audit_append_only'
      and not trigger.tgisinternal
      and trigger.tgenabled <> 'D'
  ) then
    raise exception 'Falta el trigger append-only de la auditoría.';
  end if;
end;
$contracted_cards_admin_postflight$;

commit;
