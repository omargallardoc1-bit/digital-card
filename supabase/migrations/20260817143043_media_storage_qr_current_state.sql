-- Snapshot del estado efectivo de media, Storage y QR.
-- Requiere la migración 3A del núcleo de organizaciones y tarjetas.
--
-- Ya versionado en 3A y deliberadamente no duplicado aquí:
--   private.qr_relative_luminance(text)
--   private.qr_contrast_ratio(text, text)
--   private.validate_card_media_reference_change()
--   private.validate_card_qr_settings_change()
--   constraint digital_cards_qr_settings_check
--   triggers validate_card_media_reference_change y
--            validate_card_qr_settings_change
--   policies de lectura de public.digital_cards
--
-- Los ACL de storage.objects son administrados por
-- supabase_storage_admin. Este archivo no intenta revocarlos ni
-- concederlos; la barrera efectiva para anon/authenticated es RLS.
-- No existe policy UPDATE de Storage, por lo que upsert permanece
-- bloqueado aunque el ACL administrado incluya UPDATE.

begin;

do $preconditions$
begin
  if to_regclass('public.digital_cards') is null
     or to_regclass('public.organizations') is null
     or to_regclass('public.organization_members') is null
     or to_regclass('public.organization_subscriptions') is null
     or to_regclass('public.plans') is null then
    raise exception 'Falta el núcleo organizacional versionado en la Fase 3A.';
  end if;

  if to_regclass('storage.buckets') is null
     or to_regclass('storage.objects') is null then
    raise exception 'Falta el esquema administrado de Supabase Storage.';
  end if;

  if not exists (
    select 1
    from pg_class
    where oid = 'storage.objects'::regclass
      and relrowsecurity
  ) then
    raise exception 'RLS no está habilitado en storage.objects.';
  end if;

  if (
    select count(*)
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'digital_cards'
      and column_name in (
        'photo_url',
        'logo_url',
        'cover_url',
        'qr_settings'
      )
  ) <> 4 then
    raise exception 'Faltan columnas de media/QR en digital_cards.';
  end if;

  if to_regprocedure('private.is_organization_member(uuid)') is null
     or to_regprocedure('private.has_organization_role(uuid,text[])') is null
     or to_regprocedure('private.get_effective_plan(uuid)') is null
     or to_regprocedure('private.qr_relative_luminance(text)') is null
     or to_regprocedure('private.qr_contrast_ratio(text,text)') is null
     or to_regprocedure('private.validate_card_media_reference_change()') is null
     or to_regprocedure('private.validate_card_qr_settings_change()') is null then
    raise exception 'Faltan helpers requeridos de la Fase 3A.';
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conrelid = 'public.digital_cards'::regclass
      and conname = 'digital_cards_qr_settings_check'
  ) then
    raise exception 'Falta digital_cards_qr_settings_check de la Fase 3A.';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.digital_cards'::regclass
      and tgname = 'validate_card_media_reference_change'
      and not tgisinternal
  ) or not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.digital_cards'::regclass
      and tgname = 'validate_card_qr_settings_change'
      and not tgisinternal
  ) then
    raise exception 'Faltan triggers defensivos de media/QR de la Fase 3A.';
  end if;

  if not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'digital_cards'
      and policyname = 'Organization members read digital cards'
  ) or not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'digital_cards'
      and policyname = 'Owners read their digital cards'
  ) or not exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'digital_cards'
      and policyname = 'Public reads published cards'
  ) then
    raise exception 'Faltan policies de lectura de digital_cards de la Fase 3A.';
  end if;
end;
$preconditions$;

insert into storage.buckets (
  id,
  name,
  "public",
  file_size_limit,
  allowed_mime_types,
  owner
)
values (
  'digital-card-media',
  'digital-card-media',
  false,
  2097152,
  array['image/jpeg'::text, 'image/png'::text, 'image/webp'::text],
  null
);

CREATE OR REPLACE FUNCTION private.card_media_delete_allowed(object_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  parts text[];
  target_card_id uuid;
begin
  if auth.uid() is null then
    return false;
  end if;

  parts := storage.foldername(object_name);

  if array_length(parts, 1) <> 3
     or parts[3] not in ('profile', 'logo', 'cover')
     or storage.filename(object_name) !~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
  then
    return false;
  end if;

  begin
    target_card_id := parts[2]::uuid;
  exception when others then
    return false;
  end;

  return exists (
    select 1
    from public.digital_cards card
    join public.organization_members member
      on member.organization_id = card.organization_id
    where card.id = target_card_id
      and card.organization_id is not null
      and card.owner_id::text = parts[1]
      and member.user_id = auth.uid()
      and member.status = 'active'
      and member.role in ('owner', 'admin', 'editor')
      and object_name is distinct from card.photo_url
      and object_name is distinct from card.logo_url
      and object_name is distinct from card.cover_url
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.card_media_identity_unchanged(target_card_id uuid, target_owner_id uuid, target_organization_id uuid, target_status text, target_slug text, target_published_at timestamp with time zone, target_package text)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
  select exists (
    select 1
    from public.digital_cards as existing_card
    where existing_card.id = target_card_id
      and existing_card.owner_id
        is not distinct from target_owner_id
      and existing_card.organization_id
        is not distinct from target_organization_id
      and existing_card.status
        is not distinct from target_status
      and existing_card.slug
        is not distinct from target_slug
      and existing_card.published_at
        is not distinct from target_published_at
      and existing_card.package
        is not distinct from target_package
  );
$function$;

CREATE OR REPLACE FUNCTION private.card_media_read_allowed(object_name text)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  parts text[];
  target_card_id uuid;
begin
  if auth.uid() is null then
    return false;
  end if;

  parts := storage.foldername(object_name);

  if array_length(parts, 1) <> 3
     or parts[3] not in ('profile', 'logo', 'cover')
     or storage.filename(object_name) !~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
  then
    return false;
  end if;

  begin
    target_card_id := parts[2]::uuid;
  exception when others then
    return false;
  end;

  return exists (
    select 1
    from public.digital_cards card
    join public.organization_members member
      on member.organization_id = card.organization_id
    where card.id = target_card_id
      and card.organization_id is not null
      and card.owner_id::text = parts[1]
      and member.user_id = auth.uid()
      and member.status = 'active'
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.card_media_reference_allowed(target_card_id uuid, media_type text, object_name text, expected_previous_reference text)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  initial_organization_id uuid;
  initial_owner_id uuid;
  initial_reference text;
  locked_organization_id uuid;
  locked_owner_id uuid;
  locked_reference text;
  plan_decision record;
  expected_prefix text;
begin
  if auth.uid() is null
     or target_card_id is null
     or media_type not in ('profile', 'logo', 'cover')
  then
    return false;
  end if;

  select
    card.organization_id,
    card.owner_id,
    case media_type
      when 'profile' then card.photo_url
      when 'logo' then card.logo_url
      when 'cover' then card.cover_url
    end
  into
    initial_organization_id,
    initial_owner_id,
    initial_reference
  from public.digital_cards card
  where card.id = target_card_id;

  if initial_organization_id is null or initial_owner_id is null then
    return false;
  end if;

  if initial_reference is distinct from expected_previous_reference then
    return false;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      target_card_id::text || '/' || media_type,
      0
    )
  );

  if object_name is not null then
    select *
    into plan_decision
    from private.lock_card_media_plan(
      initial_organization_id,
      media_type
    );

    if plan_decision.subscription_status is null
       or plan_decision.capability_enabled is not true
    then
      return false;
    end if;
  else
    perform 1
    from public.organizations organization
    where organization.id = initial_organization_id
    for update;

    if not found then
      return false;
    end if;
  end if;

  perform 1
  from public.organization_members member
  where member.organization_id = initial_organization_id
    and member.user_id = auth.uid()
    and member.status = 'active'
    and member.role in ('owner', 'admin', 'editor')
  for share;

  if not found then
    return false;
  end if;

  select
    card.organization_id,
    card.owner_id,
    case media_type
      when 'profile' then card.photo_url
      when 'logo' then card.logo_url
      when 'cover' then card.cover_url
    end
  into
    locked_organization_id,
    locked_owner_id,
    locked_reference
  from public.digital_cards card
  where card.id = target_card_id
  for update;

  if locked_organization_id is distinct from initial_organization_id
     or locked_owner_id is distinct from initial_owner_id
     or locked_reference is distinct from initial_reference
     or locked_reference is distinct from expected_previous_reference
  then
    return false;
  end if;

  if object_name is null then
    return true;
  end if;

  if plan_decision.subscription_status = 'past_due'
     and locked_reference is null
  then
    return false;
  end if;

  expected_prefix :=
    locked_owner_id::text || '/' ||
    target_card_id::text || '/' ||
    media_type || '/';

  if object_name not like expected_prefix || '%' then
    return false;
  end if;

  return exists (
    select 1
    from storage.objects object
    where object.bucket_id = 'digital-card-media'
      and object.name = object_name
      and array_length(storage.foldername(object.name), 1) = 3
      and (storage.foldername(object.name))[1] = locked_owner_id::text
      and (storage.foldername(object.name))[2] = target_card_id::text
      and (storage.foldername(object.name))[3] = media_type
      and storage.filename(object.name) ~*
        '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
      and object.metadata->>'mimetype'
        in ('image/jpeg', 'image/png', 'image/webp')
      and coalesce(object.metadata->>'size', '') ~ '^[0-9]+$'
      and (object.metadata->>'size')::bigint between 1 and 2097152
  );
end;
$function$;

CREATE OR REPLACE FUNCTION private.card_media_upload_allowed(object_name text, object_metadata jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  parts text[];
  target_card_id uuid;
  media_type text;
  initial_organization_id uuid;
  initial_owner_id uuid;
  initial_reference text;
  locked_organization_id uuid;
  locked_owner_id uuid;
  locked_reference text;
  plan_decision record;
  mime_type text;
begin
  if auth.uid() is null then
    return false;
  end if;

  parts := storage.foldername(object_name);

  if array_length(parts, 1) <> 3 then
    return false;
  end if;

  media_type := parts[3];

  if media_type not in ('profile', 'logo', 'cover')
     or storage.filename(object_name) !~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
  then
    return false;
  end if;

  mime_type := object_metadata->>'mimetype';

  if mime_type not in ('image/jpeg', 'image/png', 'image/webp') then
    return false;
  end if;

  if (
    storage.filename(object_name) ~* '\.(jpg|jpeg)$'
    and mime_type <> 'image/jpeg'
  ) or (
    storage.filename(object_name) ~* '\.png$'
    and mime_type <> 'image/png'
  ) or (
    storage.filename(object_name) ~* '\.webp$'
    and mime_type <> 'image/webp'
  ) then
    return false;
  end if;

  begin
    target_card_id := parts[2]::uuid;
  exception when others then
    return false;
  end;

  select
    card.organization_id,
    card.owner_id,
    case media_type
      when 'profile' then card.photo_url
      when 'logo' then card.logo_url
      when 'cover' then card.cover_url
    end
  into
    initial_organization_id,
    initial_owner_id,
    initial_reference
  from public.digital_cards card
  where card.id = target_card_id;

  if initial_organization_id is null
     or initial_owner_id is null
     or initial_owner_id::text <> parts[1]
  then
    return false;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      target_card_id::text || '/' || media_type,
      0
    )
  );

  select *
  into plan_decision
  from private.lock_card_media_plan(
    initial_organization_id,
    media_type
  );

  if plan_decision.subscription_status is null
     or plan_decision.capability_enabled is not true
  then
    return false;
  end if;

  perform 1
  from public.organization_members member
  where member.organization_id = initial_organization_id
    and member.user_id = auth.uid()
    and member.status = 'active'
    and member.role in ('owner', 'admin', 'editor')
  for share;

  if not found then
    return false;
  end if;

  select
    card.organization_id,
    card.owner_id,
    case media_type
      when 'profile' then card.photo_url
      when 'logo' then card.logo_url
      when 'cover' then card.cover_url
    end
  into
    locked_organization_id,
    locked_owner_id,
    locked_reference
  from public.digital_cards card
  where card.id = target_card_id
  for update;

  if locked_organization_id is distinct from initial_organization_id
     or locked_owner_id is distinct from initial_owner_id
     or locked_owner_id::text <> parts[1]
     or locked_reference is distinct from initial_reference
  then
    return false;
  end if;

  if plan_decision.subscription_status = 'past_due'
     and locked_reference is null
  then
    return false;
  end if;

  if exists (
    select 1
    from storage.objects object
    where object.bucket_id = 'digital-card-media'
      and (storage.foldername(object.name))[1] = parts[1]
      and (storage.foldername(object.name))[2] = parts[2]
      and (storage.foldername(object.name))[3] = media_type
      and object.name is distinct from locked_reference
  ) then
    return false;
  end if;

  return true;
end;
$function$;

CREATE OR REPLACE FUNCTION private.get_effective_qr_plan(target_organization_id uuid)
 RETURNS TABLE(subscription_id uuid, subscription_status text, plan_id uuid, qr_enabled boolean, qr_custom_colors boolean, qr_logo_enabled boolean, qr_premium_styles boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
  select
    effective.subscription_id,
    effective.subscription_status,
    effective.plan_id,
    effective.qr_enabled,
    private.qr_capability_enabled(
      plan.capabilities,
      'qr_custom_colors'
    ),
    private.qr_capability_enabled(
      plan.capabilities,
      'qr_logo_enabled'
    ),
    private.qr_capability_enabled(
      plan.capabilities,
      'qr_premium_styles'
    )
  from private.get_effective_plan(target_organization_id) as effective
  join public.plans as plan
    on plan.id = effective.plan_id;
$function$;

CREATE OR REPLACE FUNCTION private.lock_card_media_plan(target_organization_id uuid, media_type text)
 RETURNS TABLE(subscription_status text, capability_enabled boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  locked_organization_id uuid;
  locked_subscription_id uuid;
  locked_plan_id uuid;
begin
  if target_organization_id is null
     or media_type not in ('profile', 'logo', 'cover')
  then
    return;
  end if;

  select organization.id
  into locked_organization_id
  from public.organizations organization
  where organization.id = target_organization_id
    and organization.status = 'active'
  for update;

  if locked_organization_id is null then
    return;
  end if;

  select subscription.id
  into locked_subscription_id
  from public.organization_subscriptions subscription
  where subscription.organization_id = target_organization_id
    and subscription.status in ('trial', 'active', 'past_due')
    and subscription.starts_at <= now()
    and (
      subscription.expires_at is null
      or subscription.expires_at > now()
    )
  for update;

  if locked_subscription_id is null then
    return;
  end if;

  select subscription.plan_id
  into locked_plan_id
  from public.organization_subscriptions subscription
  where subscription.id = locked_subscription_id;

  perform 1
  from public.plans plan
  where plan.id = locked_plan_id
    and plan.status = 'active'
  for update;

  if not found then
    return;
  end if;

  return query
  select
    subscription.status,
    case media_type
      when 'profile' then plan.profile_image_enabled
      when 'logo' then plan.logo_image_enabled
      when 'cover' then plan.cover_image_enabled
    end
  from public.organization_subscriptions subscription
  join public.plans plan
    on plan.id = subscription.plan_id
  where subscription.id = locked_subscription_id
    and plan.id = locked_plan_id
    and plan.status = 'active';
end;
$function$;

CREATE OR REPLACE FUNCTION private.lock_effective_qr_plan(target_organization_id uuid)
 RETURNS TABLE(subscription_id uuid, subscription_status text, plan_id uuid, qr_enabled boolean, qr_custom_colors boolean, qr_logo_enabled boolean, qr_premium_styles boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  effective_plan record;
  locked_subscription public.organization_subscriptions%rowtype;
  locked_plan public.plans%rowtype;
begin
  if target_organization_id is null then
    return;
  end if;

  perform 1
  from public.organizations as organization
  where organization.id = target_organization_id
    and organization.status = 'active'
  for share;

  if not found then
    return;
  end if;

  select *
    into effective_plan
  from private.get_effective_qr_plan(target_organization_id);

  if not found then
    return;
  end if;

  select subscription.*
    into locked_subscription
  from public.organization_subscriptions as subscription
  where subscription.id = effective_plan.subscription_id
    and subscription.organization_id = target_organization_id
  for share;

  if not found
     or locked_subscription.status not in ('trial', 'active', 'past_due')
     or locked_subscription.starts_at > now()
     or (
       locked_subscription.expires_at is not null
       and locked_subscription.expires_at <= now()
     )
  then
    return;
  end if;

  select plan.*
    into locked_plan
  from public.plans as plan
  where plan.id = locked_subscription.plan_id
  for share;

  if not found
     or locked_plan.status <> 'active'
  then
    return;
  end if;

  return query
  select
    locked_subscription.id,
    locked_subscription.status,
    locked_plan.id,
    locked_plan.qr_enabled,
    private.qr_capability_enabled(
      locked_plan.capabilities,
      'qr_custom_colors'
    ),
    private.qr_capability_enabled(
      locked_plan.capabilities,
      'qr_logo_enabled'
    ),
    private.qr_capability_enabled(
      locked_plan.capabilities,
      'qr_premium_styles'
    );
end;
$function$;

CREATE OR REPLACE FUNCTION private.qr_capability_enabled(plan_capabilities jsonb, capability_name text)
 RETURNS boolean
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'pg_catalog'
AS $function$
  select case
    when jsonb_typeof(
      coalesce(plan_capabilities, '{}'::jsonb) -> capability_name
    ) = 'boolean'
    then (
      coalesce(plan_capabilities, '{}'::jsonb) ->> capability_name
    )::boolean
    else false
  end;
$function$;

CREATE OR REPLACE FUNCTION public.get_organization_qr_capabilities(target_organization_id uuid)
 RETURNS TABLE(qr_enabled boolean, qr_custom_colors boolean, qr_logo_enabled boolean, qr_premium_styles boolean, effective_subscription_status text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  effective_plan record;
  latest_subscription record;
  organization_status text;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  if target_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'La organización es obligatoria.';
  end if;

  if not private.is_organization_member(target_organization_id) then
    raise exception using
      errcode = '42501',
      message = 'No tienes acceso a esta organización.';
  end if;

  select organization.status
    into organization_status
  from public.organizations as organization
  where organization.id = target_organization_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La organización no existe.';
  end if;

  select *
    into effective_plan
  from private.get_effective_qr_plan(target_organization_id);

  if found then
    return query
    select
      effective_plan.qr_enabled,
      effective_plan.qr_custom_colors,
      effective_plan.qr_logo_enabled,
      effective_plan.qr_premium_styles,
      effective_plan.subscription_status;

    return;
  end if;

  if organization_status <> 'active' then
    return query
    select
      false,
      false,
      false,
      false,
      'organization_inactive'::text;

    return;
  end if;

  select
    subscription.status as subscription_status,
    subscription.starts_at,
    subscription.expires_at,
    plan.status as plan_status
  into latest_subscription
  from public.organization_subscriptions as subscription
  join public.plans as plan
    on plan.id = subscription.plan_id
  where subscription.organization_id = target_organization_id
  order by
    subscription.starts_at desc,
    subscription.created_at desc,
    subscription.id desc
  limit 1;

  if not found then
    return query
    select
      false,
      false,
      false,
      false,
      'no_subscription'::text;

    return;
  end if;

  return query
  select
    false,
    false,
    false,
    false,
    case
      when latest_subscription.plan_status <> 'active'
        then 'plan_inactive'
      when latest_subscription.subscription_status = 'cancelled'
        then 'cancelled'
      when latest_subscription.subscription_status = 'expired'
        then 'expired'
      when latest_subscription.expires_at is not null
       and latest_subscription.expires_at <= now()
        then 'expired'
      else 'no_subscription'
    end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_card_media_reference(target_card_id uuid, media_type text, object_path text)
 RETURNS digital_cards
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  initial_reference text;
  updated_card public.digital_cards;
  authorization_marker text;
begin
  if auth.uid() is null then
    raise exception 'Autenticación requerida.';
  end if;

  if target_card_id is null
     or media_type not in ('profile', 'logo', 'cover')
  then
    raise exception 'Tipo de medio no permitido.';
  end if;

  select case media_type
    when 'profile' then card.photo_url
    when 'logo' then card.logo_url
    when 'cover' then card.cover_url
  end
  into initial_reference
  from public.digital_cards card
  where card.id = target_card_id;

  if not found then
    raise exception 'Tarjeta no encontrada.';
  end if;

  if not private.card_media_reference_allowed(
    target_card_id,
    media_type,
    object_path,
    initial_reference
  ) then
    raise exception 'La referencia multimedia no está autorizada.';
  end if;

  authorization_marker :=
    target_card_id::text || ':' ||
    media_type || ':' ||
    coalesce(object_path, '<null>');

  perform pg_catalog.set_config(
    'digital_card.media_authorization',
    authorization_marker,
    true
  );

  if media_type = 'profile' then
    update public.digital_cards
    set photo_url = object_path,
        updated_at = now()
    where id = target_card_id
    returning * into updated_card;
  elsif media_type = 'logo' then
    update public.digital_cards
    set logo_url = object_path,
        updated_at = now()
    where id = target_card_id
    returning * into updated_card;
  else
    update public.digital_cards
    set cover_url = object_path,
        updated_at = now()
    where id = target_card_id
    returning * into updated_card;
  end if;

  perform pg_catalog.set_config(
    'digital_card.media_authorization',
    '',
    true
  );

  return updated_card;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_card_qr_settings(target_card_id uuid, dark_color text, light_color text, use_logo boolean, logo_scale numeric, premium_style text DEFAULT 'standard'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  initial_card record;
  locked_card public.digital_cards%rowtype;
  effective_plan record;

  normalized_dark_color text;
  normalized_light_color text;
  normalized_use_logo boolean;
  normalized_logo_scale numeric;
  normalized_premium_style text;

  current_dark_color text;
  current_light_color text;
  current_use_logo boolean;
  current_uses_custom_colors boolean;
  requested_uses_custom_colors boolean;

  new_settings jsonb;
  updated_settings jsonb;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  if target_card_id is null then
    raise exception using
      errcode = '22023',
      message = 'La tarjeta es obligatoria.';
  end if;

  select
    card.id,
    card.organization_id
  into initial_card
  from public.digital_cards as card
  where card.id = target_card_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La tarjeta no existe.';
  end if;

  if initial_card.organization_id is null then
    raise exception using
      errcode = '42501',
      message = 'La tarjeta no pertenece a una organización.';
  end if;

  if not private.has_organization_role(
    initial_card.organization_id,
    array['owner', 'admin', 'editor']::text[]
  ) then
    raise exception using
      errcode = '42501',
      message = 'No tienes permiso para configurar el QR de esta tarjeta.';
  end if;

  select *
    into effective_plan
  from private.lock_effective_qr_plan(
    initial_card.organization_id
  );

  if not found then
    raise exception using
      errcode = '42501',
      message = 'La organización no tiene una suscripción utilizable.';
  end if;

  select *
    into locked_card
  from public.digital_cards as card
  where card.id = target_card_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La tarjeta ya no existe.';
  end if;

  if locked_card.organization_id
     is distinct from initial_card.organization_id
  then
    raise exception using
      errcode = '40001',
      message = 'La organización de la tarjeta cambió durante la operación.';
  end if;

  if not private.has_organization_role(
    locked_card.organization_id,
    array['owner', 'admin', 'editor']::text[]
  ) then
    raise exception using
      errcode = '42501',
      message = 'Ya no tienes permiso para configurar esta tarjeta.';
  end if;

  if effective_plan.qr_enabled is not true then
    raise exception using
      errcode = '42501',
      message = 'El plan actual no incluye herramientas QR.';
  end if;

  normalized_dark_color := upper(btrim(coalesce(dark_color, '')));
  normalized_light_color := upper(btrim(coalesce(light_color, '')));
  normalized_use_logo := coalesce(use_logo, false);
  normalized_logo_scale := coalesce(logo_scale, 0.16);
  normalized_premium_style :=
    lower(btrim(coalesce(premium_style, 'standard')));

  if normalized_dark_color !~ '^#[0-9A-F]{6}$'
     or normalized_light_color !~ '^#[0-9A-F]{6}$'
  then
    raise exception using
      errcode = '22023',
      message = 'Los colores deben usar el formato hexadecimal #RRGGBB sin transparencia.';
  end if;

  if private.qr_relative_luminance(normalized_dark_color)
     >= private.qr_relative_luminance(normalized_light_color)
  then
    raise exception using
      errcode = '22023',
      message = 'El color principal debe ser más oscuro que el fondo.';
  end if;

  if private.qr_contrast_ratio(
    normalized_dark_color,
    normalized_light_color
  ) < 4.5
  then
    raise exception using
      errcode = '22023',
      message = 'Los colores del QR deben tener un contraste mínimo de 4.5:1.';
  end if;

  if normalized_logo_scale < 0.10
     or normalized_logo_scale > 0.18
  then
    raise exception using
      errcode = '22023',
      message = 'El tamaño del logo debe estar entre 0.10 y 0.18.';
  end if;

  if normalized_premium_style <> 'standard' then
    raise exception using
      errcode = '0A000',
      message = 'Los estilos QR premium todavía no están habilitados.';
  end if;

  requested_uses_custom_colors :=
    normalized_dark_color <> '#000000'
    or normalized_light_color <> '#FFFFFF';

  if requested_uses_custom_colors
     and effective_plan.qr_custom_colors is not true
  then
    raise exception using
      errcode = '42501',
      message = 'El plan actual no permite colores QR personalizados.';
  end if;

  if normalized_use_logo
     and effective_plan.qr_logo_enabled is not true
  then
    raise exception using
      errcode = '42501',
      message = 'El plan actual no permite logo central en el QR.';
  end if;

  if normalized_use_logo then
    if locked_card.logo_url is null then
      raise exception using
        errcode = '22023',
        message = 'La tarjeta no tiene un logo activo.';
    end if;

    if not exists (
      select 1
      from storage.objects as object
      where object.bucket_id = 'digital-card-media'
        and object.name = locked_card.logo_url
    ) then
      raise exception using
        errcode = '22023',
        message = 'El logo activo de la tarjeta no existe en Storage.';
    end if;
  end if;

  current_dark_color :=
    upper(coalesce(
      locked_card.qr_settings ->> 'dark_color',
      '#000000'
    ));

  current_light_color :=
    upper(coalesce(
      locked_card.qr_settings ->> 'light_color',
      '#FFFFFF'
    ));

  current_use_logo :=
    coalesce(
      (locked_card.qr_settings ->> 'use_logo')::boolean,
      false
    );

  current_uses_custom_colors :=
    current_dark_color <> '#000000'
    or current_light_color <> '#FFFFFF';

  if effective_plan.subscription_status = 'past_due' then
    if requested_uses_custom_colors
       and not current_uses_custom_colors
    then
      raise exception using
        errcode = '42501',
        message = 'Una suscripción past_due no puede activar colores personalizados nuevos.';
    end if;

    if normalized_use_logo
       and not current_use_logo
    then
      raise exception using
        errcode = '42501',
        message = 'Una suscripción past_due no puede activar un logo QR nuevo.';
    end if;
  end if;

  new_settings := jsonb_build_object(
    'dark_color', normalized_dark_color,
    'light_color', normalized_light_color,
    'use_logo', normalized_use_logo,
    'logo_scale', normalized_logo_scale,
    'premium_style', 'standard'
  );

  perform pg_catalog.set_config(
    'digital_card.qr_authorization',
    locked_card.id::text,
    true
  );

  update public.digital_cards as card
  set
    qr_settings = new_settings,
    updated_at = now()
  where card.id = locked_card.id
  returning card.qr_settings
  into updated_settings;

  perform pg_catalog.set_config(
    'digital_card.qr_authorization',
    '',
    true
  );

  return updated_settings;
end;
$function$;

create policy "Organization members read card media"
on storage.objects
as permissive
for select
to "authenticated"
using (((bucket_id = 'digital-card-media'::text) AND private.card_media_read_allowed(name)))
;

create policy "Organization roles delete unreferenced card media"
on storage.objects
as permissive
for delete
to "authenticated"
using (((bucket_id = 'digital-card-media'::text) AND private.card_media_delete_allowed(name)))
;

create policy "Organization roles upload card media"
on storage.objects
as permissive
for insert
to "authenticated"
with check (((bucket_id = 'digital-card-media'::text) AND private.card_media_upload_allowed(name, metadata)))
;

create policy "Published card media is publicly readable"
on storage.objects
as permissive
for select
to "anon", "authenticated"
using (((bucket_id = 'digital-card-media'::text) AND storage.allow_any_operation(ARRAY['object.get_authenticated_info'::text, 'object.get_authenticated'::text, 'storage.object.sign'::text]) AND (array_length(storage.foldername(name), 1) = 3) AND ((storage.foldername(name))[3] = ANY (ARRAY['profile'::text, 'logo'::text, 'cover'::text])) AND (storage.filename(name) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'::text) AND (EXISTS ( SELECT 1
   FROM digital_cards card
  WHERE (((card.id)::text = (storage.foldername(objects.name))[2]) AND ((card.owner_id)::text = (storage.foldername(objects.name))[1]) AND (card.status = 'published'::text) AND ((((storage.foldername(objects.name))[3] = 'profile'::text) AND (card.photo_url = objects.name)) OR (((storage.foldername(objects.name))[3] = 'logo'::text) AND (card.logo_url = objects.name)) OR (((storage.foldername(objects.name))[3] = 'cover'::text) AND (card.cover_url = objects.name))))))))
;

-- ACL exactas de funciones del bloque media/QR.
revoke all on function private.card_media_delete_allowed(text) from public, anon, authenticated, service_role;
revoke all on function private.card_media_identity_unchanged(uuid, uuid, uuid, text, text, timestamp with time zone, text) from public, anon, authenticated, service_role;
revoke all on function private.card_media_read_allowed(text) from public, anon, authenticated, service_role;
revoke all on function private.card_media_reference_allowed(uuid, text, text, text) from public, anon, authenticated, service_role;
revoke all on function private.card_media_upload_allowed(text, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.get_effective_qr_plan(uuid) from public, anon, authenticated, service_role;
revoke all on function private.lock_card_media_plan(uuid, text) from public, anon, authenticated, service_role;
revoke all on function private.lock_effective_qr_plan(uuid) from public, anon, authenticated, service_role;
revoke all on function private.qr_capability_enabled(jsonb, text) from public, anon, authenticated, service_role;
revoke all on function public.get_organization_qr_capabilities(uuid) from public, anon, authenticated, service_role;
revoke all on function public.set_card_media_reference(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.set_card_qr_settings(uuid, text, text, boolean, numeric, text) from public, anon, authenticated, service_role;

grant execute on function private.card_media_delete_allowed(text) to authenticated;
grant execute on function private.card_media_read_allowed(text) to authenticated;
grant execute on function private.card_media_upload_allowed(text, jsonb) to authenticated;

grant execute on function public.get_organization_qr_capabilities(uuid) to authenticated;
grant execute on function public.set_card_media_reference(uuid, text, text) to authenticated;
grant execute on function public.set_card_qr_settings(
  uuid, text, text, boolean, numeric, text
) to authenticated;

commit;
