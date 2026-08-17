-- Snapshot del estado efectivo del núcleo de organizaciones y tarjetas.
-- No contiene datos de producción ni el catálogo de filas de plans.
-- La migración de invitaciones ya versionada depende de este núcleo.
-- Los flujos completos de media y QR (sus RPC específicas) se versionarán
-- en fases posteriores; aquí se preservan únicamente los validadores que
-- son dependencias directas de digital_cards.
--
-- Este archivo es un snapshot de baseline. Antes de aplicar todos los
-- snapshots a un proyecto nuevo debe coordinarse/squashearse el orden del
-- historial, porque la migración de invitaciones fue versionada primero.

begin;

create schema if not exists private authorization postgres;

revoke all on schema private from public, anon, authenticated, service_role;
grant usage on schema private to authenticated;

CREATE OR REPLACE FUNCTION private.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
begin new.updated_at:=statement_timestamp(); return new; end;
$function$;

CREATE OR REPLACE FUNCTION private.qr_relative_luminance(hex_color text)
 RETURNS numeric
 LANGUAGE plpgsql
 IMMUTABLE STRICT
 SET search_path TO 'pg_catalog'
AS $function$
declare
  normalized_color text;
  red_channel numeric;
  green_channel numeric;
  blue_channel numeric;
begin
  normalized_color := upper(hex_color);

  if normalized_color !~ '^#[0-9A-F]{6}$' then
    raise exception using
      errcode = '22023',
      message = 'El color debe usar el formato hexadecimal #RRGGBB.';
  end if;

  red_channel :=
    get_byte(decode(substr(normalized_color, 2, 2), 'hex'), 0) / 255.0;

  green_channel :=
    get_byte(decode(substr(normalized_color, 4, 2), 'hex'), 0) / 255.0;

  blue_channel :=
    get_byte(decode(substr(normalized_color, 6, 2), 'hex'), 0) / 255.0;

  red_channel := case
    when red_channel <= 0.04045
      then red_channel / 12.92
    else power((red_channel + 0.055) / 1.055, 2.4)
  end;

  green_channel := case
    when green_channel <= 0.04045
      then green_channel / 12.92
    else power((green_channel + 0.055) / 1.055, 2.4)
  end;

  blue_channel := case
    when blue_channel <= 0.04045
      then blue_channel / 12.92
    else power((blue_channel + 0.055) / 1.055, 2.4)
  end;

  return
    (0.2126 * red_channel) +
    (0.7152 * green_channel) +
    (0.0722 * blue_channel);
end;
$function$;

CREATE OR REPLACE FUNCTION private.qr_contrast_ratio(first_color text, second_color text)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE STRICT
 SET search_path TO 'pg_catalog'
AS $function$
  select
    (
      greatest(
        private.qr_relative_luminance(first_color),
        private.qr_relative_luminance(second_color)
      ) + 0.05
    )
    /
    (
      least(
        private.qr_relative_luminance(first_color),
        private.qr_relative_luminance(second_color)
      ) + 0.05
    );
$function$;

create table public."plans" (
  "id" uuid default gen_random_uuid() not null,
  "code" text not null,
  "name" text not null,
  "description" text,
  "max_cards" integer not null,
  "max_members" integer not null,
  "lead_capture_enabled" boolean default false not null,
  "analytics_enabled" boolean default false not null,
  "analytics_history_days" integer,
  "qr_enabled" boolean default false not null,
  "profile_image_enabled" boolean default false not null,
  "logo_image_enabled" boolean default false not null,
  "cover_image_enabled" boolean default false not null,
  "csv_export_enabled" boolean default false not null,
  "visual_customization_level" text default 'basic'::text not null,
  "video_enabled" boolean default false not null,
  "payment_card_enabled" boolean default false not null,
  "support_level" text default 'standard'::text not null,
  "capabilities" jsonb default '{}'::jsonb not null,
  "configuration_notes" text not null,
  "status" text default 'active'::text not null,
  "sort_order" integer not null,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  constraint "plans_analytics_consistency_check" CHECK (analytics_enabled = true OR analytics_history_days IS NULL),
  constraint "plans_analytics_history_check" CHECK (analytics_history_days IS NULL OR analytics_history_days > 0),
  constraint "plans_capabilities_object_check" CHECK (jsonb_typeof(capabilities) = 'object'::text),
  constraint "plans_code_format_check" CHECK (code ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'::text),
  constraint "plans_code_key" UNIQUE (code),
  constraint "plans_limits_check" CHECK (max_cards > 0 AND max_members > 0),
  constraint "plans_name_key" UNIQUE (name),
  constraint "plans_name_not_blank_check" CHECK (NULLIF(btrim(name), ''::text) IS NOT NULL),
  constraint "plans_pkey" PRIMARY KEY (id),
  constraint "plans_qr_capabilities_boolean_check" CHECK ((NOT capabilities ? 'qr_custom_colors'::text OR jsonb_typeof(capabilities -> 'qr_custom_colors'::text) = 'boolean'::text) AND (NOT capabilities ? 'qr_logo_enabled'::text OR jsonb_typeof(capabilities -> 'qr_logo_enabled'::text) = 'boolean'::text) AND (NOT capabilities ? 'qr_premium_styles'::text OR jsonb_typeof(capabilities -> 'qr_premium_styles'::text) = 'boolean'::text)),
  constraint "plans_sort_order_check" CHECK (sort_order > 0),
  constraint "plans_status_check" CHECK (status = ANY (ARRAY['active'::text, 'inactive'::text, 'archived'::text])),
  constraint "plans_support_level_check" CHECK (support_level = ANY (ARRAY['standard'::text, 'priority'::text, 'sla'::text])),
  constraint "plans_timestamps_check" CHECK (updated_at >= created_at),
  constraint "plans_visual_customization_level_check" CHECK (visual_customization_level = ANY (ARRAY['basic'::text, 'standard'::text, 'advanced'::text]))
);

create table public."organizations" (
  "id" uuid default gen_random_uuid() not null,
  "name" text not null,
  "legal_name" text,
  "phone" text,
  "email" text,
  "website" text,
  "logo_url" text,
  "status" text default 'active'::text not null,
  "created_by" uuid not null,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  constraint "organizations_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE RESTRICT,
  constraint "organizations_email_format_check" CHECK (email IS NULL OR email ~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'::text),
  constraint "organizations_email_length_check" CHECK (email IS NULL OR char_length(email) <= 320),
  constraint "organizations_legal_name_length_check" CHECK (legal_name IS NULL OR char_length(legal_name) <= 240),
  constraint "organizations_logo_url_length_check" CHECK (logo_url IS NULL OR char_length(logo_url) <= 2048),
  constraint "organizations_name_length_check" CHECK (char_length(name) <= 160),
  constraint "organizations_name_not_blank_check" CHECK (NULLIF(btrim(name), ''::text) IS NOT NULL),
  constraint "organizations_phone_length_check" CHECK (phone IS NULL OR char_length(phone) <= 40),
  constraint "organizations_pkey" PRIMARY KEY (id),
  constraint "organizations_status_check" CHECK (status = ANY (ARRAY['active'::text, 'suspended'::text, 'archived'::text])),
  constraint "organizations_timestamps_check" CHECK (updated_at >= created_at),
  constraint "organizations_website_length_check" CHECK (website IS NULL OR char_length(website) <= 2048)
);

create table public."organization_members" (
  "organization_id" uuid not null,
  "user_id" uuid not null,
  "role" text not null,
  "status" text default 'active'::text not null,
  "created_by" uuid,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  constraint "organization_members_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL,
  constraint "organization_members_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE CASCADE,
  constraint "organization_members_pkey" PRIMARY KEY (organization_id, user_id),
  constraint "organization_members_role_check" CHECK (role = ANY (ARRAY['owner'::text, 'admin'::text, 'editor'::text, 'viewer'::text])),
  constraint "organization_members_status_check" CHECK (status = ANY (ARRAY['active'::text, 'disabled'::text])),
  constraint "organization_members_timestamps_check" CHECK (updated_at >= created_at),
  constraint "organization_members_user_id_fkey" FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE
);

create table public."organization_subscriptions" (
  "id" uuid default gen_random_uuid() not null,
  "organization_id" uuid not null,
  "plan_id" uuid not null,
  "status" text not null,
  "starts_at" timestamp with time zone not null,
  "expires_at" timestamp with time zone,
  "renewal_type" text default 'manual'::text not null,
  "amount" numeric(12,2),
  "currency" text,
  "payment_provider" text,
  "external_subscription_id" text,
  "created_by" uuid,
  "notes" text,
  "created_at" timestamp with time zone default now() not null,
  "updated_at" timestamp with time zone default now() not null,
  constraint "organization_subscriptions_amount_check" CHECK (amount IS NULL OR amount >= 0::numeric),
  constraint "organization_subscriptions_amount_currency_check" CHECK (amount IS NULL AND currency IS NULL OR amount IS NOT NULL AND currency IS NOT NULL),
  constraint "organization_subscriptions_created_by_fkey" FOREIGN KEY (created_by) REFERENCES auth.users(id) ON DELETE SET NULL,
  constraint "organization_subscriptions_currency_check" CHECK (currency IS NULL OR currency ~ '^[A-Z]{3}$'::text),
  constraint "organization_subscriptions_dates_check" CHECK (expires_at IS NULL OR expires_at > starts_at),
  constraint "organization_subscriptions_external_id_length_check" CHECK (external_subscription_id IS NULL OR char_length(external_subscription_id) <= 255),
  constraint "organization_subscriptions_external_pair_check" CHECK (external_subscription_id IS NULL OR payment_provider IS NOT NULL),
  constraint "organization_subscriptions_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  constraint "organization_subscriptions_payment_provider_length_check" CHECK (payment_provider IS NULL OR char_length(payment_provider) <= 80),
  constraint "organization_subscriptions_pkey" PRIMARY KEY (id),
  constraint "organization_subscriptions_plan_id_fkey" FOREIGN KEY (plan_id) REFERENCES plans(id) ON DELETE RESTRICT,
  constraint "organization_subscriptions_renewal_type_check" CHECK (renewal_type = ANY (ARRAY['none'::text, 'manual'::text, 'automatic'::text])),
  constraint "organization_subscriptions_status_check" CHECK (status = ANY (ARRAY['trial'::text, 'active'::text, 'past_due'::text, 'cancelled'::text, 'expired'::text])),
  constraint "organization_subscriptions_timestamps_check" CHECK (updated_at >= created_at)
);

create table public."digital_cards" (
  "id" uuid default gen_random_uuid() not null,
  "slug" text not null,
  "name" text default 'Nueva persona'::text not null,
  "position" text default 'Profesional'::text,
  "company" text default 'Nueva empresa'::text,
  "slogan" text default 'Tu marca. Tu conexión.'::text,
  "description" text,
  "phone" text,
  "whatsapp" text,
  "email" text,
  "website" text,
  "photo_url" text,
  "logo_url" text,
  "package" text default 'elite'::text,
  "status" text default 'draft'::text not null,
  "views" integer default 0,
  "prospects" integer default 0,
  "created_at" timestamp with time zone default now(),
  "updated_at" timestamp with time zone default now(),
  "owner_id" uuid not null,
  "capture_enabled" boolean default false not null,
  "template" text default 'elegant'::text not null,
  "theme" jsonb default '{}'::jsonb not null,
  "location" text,
  "published_at" timestamp with time zone,
  "cover_url" text,
  "organization_id" uuid,
  "qr_settings" jsonb default '{"use_logo": false, "dark_color": "#000000", "logo_scale": 0.16, "light_color": "#FFFFFF", "premium_style": "standard"}'::jsonb not null,
  constraint "digital_cards_organization_id_fkey" FOREIGN KEY (organization_id) REFERENCES organizations(id) ON DELETE RESTRICT,
  constraint "digital_cards_owner_id_fkey" FOREIGN KEY (owner_id) REFERENCES auth.users(id) ON DELETE RESTRICT,
  constraint "digital_cards_pkey" PRIMARY KEY (id),
  constraint "digital_cards_qr_settings_check" CHECK (jsonb_typeof(qr_settings) = 'object'::text AND qr_settings ?& ARRAY['dark_color'::text, 'light_color'::text, 'use_logo'::text, 'logo_scale'::text, 'premium_style'::text] AND (qr_settings - ARRAY['dark_color'::text, 'light_color'::text, 'use_logo'::text, 'logo_scale'::text, 'premium_style'::text]) = '{}'::jsonb AND jsonb_typeof(qr_settings -> 'dark_color'::text) = 'string'::text AND (qr_settings ->> 'dark_color'::text) ~ '^#[0-9A-F]{6}$'::text AND jsonb_typeof(qr_settings -> 'light_color'::text) = 'string'::text AND (qr_settings ->> 'light_color'::text) ~ '^#[0-9A-F]{6}$'::text AND jsonb_typeof(qr_settings -> 'use_logo'::text) = 'boolean'::text AND jsonb_typeof(qr_settings -> 'logo_scale'::text) = 'number'::text AND ((qr_settings ->> 'logo_scale'::text)::numeric) >= 0.10 AND ((qr_settings ->> 'logo_scale'::text)::numeric) <= 0.18 AND jsonb_typeof(qr_settings -> 'premium_style'::text) = 'string'::text AND (qr_settings ->> 'premium_style'::text) = 'standard'::text AND private.qr_relative_luminance(qr_settings ->> 'dark_color'::text) < private.qr_relative_luminance(qr_settings ->> 'light_color'::text) AND private.qr_contrast_ratio(qr_settings ->> 'dark_color'::text, qr_settings ->> 'light_color'::text) >= 4.5),
  constraint "digital_cards_slug_key" UNIQUE (slug),
  constraint "digital_cards_status_check" CHECK (status = ANY (ARRAY['draft'::text, 'published'::text, 'archived'::text])),
  constraint "digital_cards_theme_object_check" CHECK (jsonb_typeof(theme) = 'object'::text)
);

CREATE OR REPLACE FUNCTION private.is_organization_member(target_organization_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 select target_organization_id is not null and(select auth.uid()) is not null and exists(
  select 1 from public.organization_members member
  where member.organization_id=target_organization_id and member.user_id=(select auth.uid()) and member.status='active');
$function$;

CREATE OR REPLACE FUNCTION private.has_organization_role(target_organization_id uuid, allowed_roles text[])
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 select target_organization_id is not null and allowed_roles is not null and(select auth.uid()) is not null and exists(
  select 1 from public.organization_members member
  where member.organization_id=target_organization_id and member.user_id=(select auth.uid())
   and member.status='active' and member.role=any(allowed_roles));
$function$;

CREATE OR REPLACE FUNCTION private.get_effective_plan(target_organization_id uuid)
 RETURNS TABLE(subscription_id uuid, subscription_status text, plan_id uuid, plan_code text, plan_name text, max_cards integer, max_members integer, lead_capture_enabled boolean, analytics_enabled boolean, analytics_history_days integer, qr_enabled boolean, profile_image_enabled boolean, logo_image_enabled boolean, cover_image_enabled boolean, csv_export_enabled boolean, video_enabled boolean)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
  select
    subscription.id,
    subscription.status,
    plan.id,
    plan.code,
    plan.name,
    plan.max_cards,
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

CREATE OR REPLACE FUNCTION private.ensure_organization_has_active_owner()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  affected_organization_id uuid;
begin
  affected_organization_id := old.organization_id;

  if tg_op = 'UPDATE' then
    if old.role <> 'owner'
       or old.status <> 'active'
       or (
         new.role = 'owner'
         and new.status = 'active'
       )
    then
      return new;
    end if;
  elsif tg_op = 'DELETE' then
    if old.role <> 'owner'
       or old.status <> 'active'
    then
      return old;
    end if;
  end if;

  /*
   * El cascade por eliminación de la organización completa es válido.
   * El cascade desde auth.users sí será bloqueado si elimina al último
   * owner de una organización que continúa existiendo.
   */
  if not exists (
    select 1
    from public.organizations as organization
    where organization.id = affected_organization_id
  ) then
    return case
      when tg_op = 'DELETE' then old
      else new
    end;
  end if;

  if not exists (
    select 1
    from public.organization_members as member
    where member.organization_id = affected_organization_id
      and member.role = 'owner'
      and member.status = 'active'
  ) then
    raise exception using
      errcode = '23514',
      message =
        'La organización debe conservar al menos un owner activo.';
  end if;

  return case
    when tg_op = 'DELETE' then old
    else new
  end;
end;
$function$;

CREATE OR REPLACE FUNCTION private.validate_card_media_reference_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare
  authorization_marker text;
  expected_marker text;
  changed_type text;
  changed_path text;
begin
  if new.photo_url is distinct from old.photo_url then
    changed_type := 'profile';
    changed_path := new.photo_url;
  end if;

  if new.logo_url is distinct from old.logo_url then
    if changed_type is not null then
      raise exception 'Solo puede cambiarse una referencia por operación.';
    end if;
    changed_type := 'logo';
    changed_path := new.logo_url;
  end if;

  if new.cover_url is distinct from old.cover_url then
    if changed_type is not null then
      raise exception 'Solo puede cambiarse una referencia por operación.';
    end if;
    changed_type := 'cover';
    changed_path := new.cover_url;
  end if;

  if changed_type is null then
    return new;
  end if;

  authorization_marker :=
    current_setting('digital_card.media_authorization', true);

  expected_marker :=
    old.id::text || ':' ||
    changed_type || ':' ||
    coalesce(changed_path, '<null>');

  if authorization_marker is distinct from expected_marker then
    raise exception
      'La referencia multimedia debe modificarse mediante set_card_media_reference.';
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION private.validate_card_qr_settings_change()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog'
AS $function$
declare
  expected_marker text;
  actual_marker text;
begin
  if old.qr_settings is not distinct from new.qr_settings then
    return new;
  end if;

  expected_marker := old.id::text;
  actual_marker := current_setting(
    'digital_card.qr_authorization',
    true
  );

  if actual_marker is distinct from expected_marker then
    raise exception using
      errcode = '42501',
      message = 'Las preferencias QR solo pueden modificarse mediante la RPC autorizada.';
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.digital_cards_set_timestamps()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
begin
  new.updated_at = now();

  if new.status = 'published' and new.published_at is null then
    new.published_at = now();
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_organization_card(target_organization_id uuid, card_slug text, card_name text, card_position text DEFAULT NULL::text, card_company text DEFAULT NULL::text, card_slogan text DEFAULT NULL::text, card_description text DEFAULT NULL::text, card_phone text DEFAULT NULL::text, card_whatsapp text DEFAULT NULL::text, card_email text DEFAULT NULL::text, card_website text DEFAULT NULL::text, card_location text DEFAULT NULL::text, card_capture_enabled boolean DEFAULT false)
 RETURNS digital_cards
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  organization_status text;
  effective_plan record;
  consumed_cards bigint;
  normalized_slug text;
  normalized_name text;
  created_card public.digital_cards%rowtype;
begin
  current_user_id := auth.uid();

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

  normalized_slug := lower(btrim(coalesce(card_slug, '')));
  normalized_name := btrim(coalesce(card_name, ''));

  if normalized_slug = ''
     or char_length(normalized_slug) > 120
     or normalized_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' then
    raise exception using
      errcode = '22023',
      message = 'El slug no es válido.';
  end if;

  if normalized_name = ''
     or char_length(normalized_name) > 120 then
    raise exception using
      errcode = '22023',
      message = 'El nombre es obligatorio y debe tener máximo 120 caracteres.';
  end if;

  if char_length(coalesce(card_position, '')) > 120
     or char_length(coalesce(card_company, '')) > 160
     or char_length(coalesce(card_slogan, '')) > 200
     or char_length(coalesce(card_description, '')) > 2000
     or char_length(coalesce(card_phone, '')) > 40
     or char_length(coalesce(card_whatsapp, '')) > 40
     or char_length(coalesce(card_email, '')) > 254
     or char_length(coalesce(card_website, '')) > 500
     or char_length(coalesce(card_location, '')) > 300 then
    raise exception using
      errcode = '22023',
      message = 'Uno o más campos exceden la longitud permitida.';
  end if;

  select organization.status
    into organization_status
  from public.organizations as organization
  where organization.id = target_organization_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La organización no existe.';
  end if;

  if organization_status <> 'active' then
    raise exception using
      errcode = '42501',
      message = 'La organización no está activa.';
  end if;

  if not private.has_organization_role(
    target_organization_id,
    array['owner', 'admin', 'editor']::text[]
  ) then
    raise exception using
      errcode = '42501',
      message = 'No tienes permiso para crear tarjetas en esta organización.';
  end if;

  select *
    into effective_plan
  from private.get_effective_plan(target_organization_id);

  if not found then
    raise exception using
      errcode = '42501',
      message = 'La organización no tiene una suscripción utilizable.';
  end if;

  if effective_plan.subscription_status = 'past_due' then
    raise exception using
      errcode = '42501',
      message = 'La suscripción tiene un pago pendiente y no permite crear nuevas tarjetas.';
  end if;

  select count(*)
    into consumed_cards
  from public.digital_cards as card
  where card.organization_id = target_organization_id
    and card.status in ('draft', 'published');

  if consumed_cards >= effective_plan.max_cards then
    raise exception using
      errcode = 'P0001',
      message = 'La organización alcanzó el máximo de Digital Cards de su plan.';
  end if;

  insert into public.digital_cards (
    slug,
    name,
    position,
    company,
    slogan,
    description,
    phone,
    whatsapp,
    email,
    website,
    location,
    capture_enabled,
    status,
    owner_id,
    organization_id
  )
  values (
    normalized_slug,
    normalized_name,
    nullif(btrim(coalesce(card_position, '')), ''),
    nullif(btrim(coalesce(card_company, '')), ''),
    nullif(btrim(coalesce(card_slogan, '')), ''),
    nullif(btrim(coalesce(card_description, '')), ''),
    nullif(btrim(coalesce(card_phone, '')), ''),
    nullif(btrim(coalesce(card_whatsapp, '')), ''),
    nullif(btrim(coalesce(card_email, '')), ''),
    nullif(btrim(coalesce(card_website, '')), ''),
    nullif(btrim(coalesce(card_location, '')), ''),
    coalesce(card_capture_enabled, false),
    'draft',
    current_user_id,
    target_organization_id
  )
  returning *
    into created_card;

  return created_card;
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_organization_card(target_card_id uuid, card_name text, card_position text DEFAULT NULL::text, card_company text DEFAULT NULL::text, card_slogan text DEFAULT NULL::text, card_description text DEFAULT NULL::text, card_phone text DEFAULT NULL::text, card_whatsapp text DEFAULT NULL::text, card_email text DEFAULT NULL::text, card_website text DEFAULT NULL::text, card_location text DEFAULT NULL::text, card_capture_enabled boolean DEFAULT false)
 RETURNS digital_cards
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  existing_card public.digital_cards%rowtype;
  updated_card public.digital_cards%rowtype;
  normalized_name text;
begin
  current_user_id := auth.uid();

  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  if target_card_id is null then
    raise exception using
      errcode = '22023',
      message = 'La tarjeta es obligatoria.';
  end if;

  normalized_name := btrim(coalesce(card_name, ''));

  if normalized_name = ''
     or char_length(normalized_name) > 120 then
    raise exception using
      errcode = '22023',
      message = 'El nombre es obligatorio y debe tener máximo 120 caracteres.';
  end if;

  if char_length(coalesce(card_position, '')) > 120
     or char_length(coalesce(card_company, '')) > 160
     or char_length(coalesce(card_slogan, '')) > 200
     or char_length(coalesce(card_description, '')) > 2000
     or char_length(coalesce(card_phone, '')) > 40
     or char_length(coalesce(card_whatsapp, '')) > 40
     or char_length(coalesce(card_email, '')) > 254
     or char_length(coalesce(card_website, '')) > 500
     or char_length(coalesce(card_location, '')) > 300 then
    raise exception using
      errcode = '22023',
      message = 'Uno o más campos exceden la longitud permitida.';
  end if;

  select *
    into existing_card
  from public.digital_cards as card
  where card.id = target_card_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La tarjeta no existe.';
  end if;

  if existing_card.organization_id is null then
    raise exception using
      errcode = '42501',
      message = 'La tarjeta todavía no está asociada a una organización.';
  end if;

  if not private.has_organization_role(
    existing_card.organization_id,
    array['owner', 'admin', 'editor']::text[]
  ) then
    raise exception using
      errcode = '42501',
      message = 'No tienes permiso para editar esta tarjeta.';
  end if;

  if not exists (
    select 1
    from private.get_effective_plan(existing_card.organization_id)
  ) then
    raise exception using
      errcode = '42501',
      message = 'La organización no tiene una suscripción utilizable.';
  end if;

  update public.digital_cards as card
  set
    name = normalized_name,
    position = nullif(btrim(coalesce(card_position, '')), ''),
    company = nullif(btrim(coalesce(card_company, '')), ''),
    slogan = nullif(btrim(coalesce(card_slogan, '')), ''),
    description = nullif(btrim(coalesce(card_description, '')), ''),
    phone = nullif(btrim(coalesce(card_phone, '')), ''),
    whatsapp = nullif(btrim(coalesce(card_whatsapp, '')), ''),
    email = nullif(btrim(coalesce(card_email, '')), ''),
    website = nullif(btrim(coalesce(card_website, '')), ''),
    location = nullif(btrim(coalesce(card_location, '')), ''),
    capture_enabled = coalesce(card_capture_enabled, false)
  where card.id = existing_card.id
  returning *
    into updated_card;

  return updated_card;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_card_status(target_card_id uuid, target_status text)
 RETURNS digital_cards
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  initial_organization_id uuid;
  locked_organization_id uuid;
  organization_status text;
  existing_card public.digital_cards%rowtype;
  effective_plan record;
  consumed_cards bigint;
  updated_card public.digital_cards%rowtype;
  normalized_status text;
begin
  current_user_id := auth.uid();

  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  if target_card_id is null then
    raise exception using
      errcode = '22023',
      message = 'La tarjeta es obligatoria.';
  end if;

  normalized_status := lower(btrim(coalesce(target_status, '')));

  if normalized_status not in ('draft', 'published', 'archived') then
    raise exception using
      errcode = '22023',
      message = 'El estado solicitado no es válido.';
  end if;

  select card.organization_id
    into initial_organization_id
  from public.digital_cards as card
  where card.id = target_card_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La tarjeta no existe.';
  end if;

  if initial_organization_id is null then
    raise exception using
      errcode = '42501',
      message = 'La tarjeta todavía no está asociada a una organización.';
  end if;

  select organization.id, organization.status
    into locked_organization_id, organization_status
  from public.organizations as organization
  where organization.id = initial_organization_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La organización no existe.';
  end if;

  select *
    into existing_card
  from public.digital_cards as card
  where card.id = target_card_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La tarjeta no existe.';
  end if;

  if existing_card.organization_id is distinct from locked_organization_id then
    raise exception using
      errcode = '40001',
      message = 'La organización de la tarjeta cambió durante la operación. Intenta nuevamente.';
  end if;

  if not private.has_organization_role(
    existing_card.organization_id,
    array['owner', 'admin', 'editor']::text[]
  ) then
    raise exception using
      errcode = '42501',
      message = 'No tienes permiso para cambiar el estado de esta tarjeta.';
  end if;

  if normalized_status = existing_card.status then
    return existing_card;
  end if;

  if normalized_status <> 'archived' then
    if organization_status <> 'active' then
      raise exception using
        errcode = '42501',
        message = 'La organización no está activa.';
    end if;

    select *
      into effective_plan
    from private.get_effective_plan(existing_card.organization_id);

    if not found then
      raise exception using
        errcode = '42501',
        message = 'La organización no tiene una suscripción utilizable.';
    end if;

    if existing_card.status = 'archived'
       and effective_plan.subscription_status = 'past_due' then
      raise exception using
        errcode = '42501',
        message = 'La suscripción tiene un pago pendiente y no permite reactivar tarjetas archivadas.';
    end if;

    if existing_card.status = 'archived' then
      select count(*)
        into consumed_cards
      from public.digital_cards as card
      where card.organization_id = existing_card.organization_id
        and card.status in ('draft', 'published');

      if consumed_cards >= effective_plan.max_cards then
        raise exception using
          errcode = 'P0001',
          message = 'La organización alcanzó el máximo de Digital Cards de su plan.';
      end if;
    end if;
  end if;

  if normalized_status = 'published'
     and (
       btrim(coalesce(existing_card.name, '')) = ''
       or btrim(coalesce(existing_card.slug, '')) = ''
     ) then
    raise exception using
      errcode = '22023',
      message = 'La tarjeta necesita nombre y slug antes de publicarse.';
  end if;

  update public.digital_cards as card
  set
    status = normalized_status,
    published_at = case
      when normalized_status = 'published'
       and existing_card.status <> 'published'
        then now()
      else card.published_at
    end
  where card.id = existing_card.id
  returning *
    into updated_card;

  return updated_card;
end;
$function$;
CREATE INDEX plans_status_sort_order_idx ON public.plans USING btree (status, sort_order);

CREATE INDEX organizations_created_by_idx ON public.organizations USING btree (created_by);

CREATE INDEX organizations_status_idx ON public.organizations USING btree (status);

CREATE INDEX organization_members_active_org_idx ON public.organization_members USING btree (organization_id, role, user_id) WHERE (status = 'active'::text);

CREATE INDEX organization_members_active_user_idx ON public.organization_members USING btree (user_id, organization_id, role) WHERE (status = 'active'::text);

CREATE INDEX organization_members_user_id_idx ON public.organization_members USING btree (user_id, organization_id);

CREATE UNIQUE INDEX organization_subscriptions_external_id_idx ON public.organization_subscriptions USING btree (payment_provider, external_subscription_id) WHERE (external_subscription_id IS NOT NULL);

CREATE UNIQUE INDEX organization_subscriptions_one_current_idx ON public.organization_subscriptions USING btree (organization_id) WHERE (status = ANY (ARRAY['trial'::text, 'active'::text, 'past_due'::text]));

CREATE INDEX organization_subscriptions_organization_created_at_idx ON public.organization_subscriptions USING btree (organization_id, created_at DESC);

CREATE INDEX organization_subscriptions_plan_id_idx ON public.organization_subscriptions USING btree (plan_id);

CREATE INDEX digital_cards_organization_status_idx ON public.digital_cards USING btree (organization_id, status) WHERE (organization_id IS NOT NULL);

CREATE INDEX digital_cards_organization_updated_at_idx ON public.digital_cards USING btree (organization_id, updated_at DESC) WHERE (organization_id IS NOT NULL);

CREATE INDEX digital_cards_owner_id_idx ON public.digital_cards USING btree (owner_id);

CREATE TRIGGER plans_set_updated_at BEFORE UPDATE ON plans FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

CREATE TRIGGER organizations_set_updated_at BEFORE UPDATE ON organizations FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

CREATE CONSTRAINT TRIGGER organization_members_require_active_owner AFTER DELETE OR UPDATE OF role, status ON organization_members DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION private.ensure_organization_has_active_owner();

CREATE TRIGGER organization_members_set_updated_at BEFORE UPDATE ON organization_members FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

CREATE TRIGGER organization_subscriptions_set_updated_at BEFORE UPDATE ON organization_subscriptions FOR EACH ROW EXECUTE FUNCTION private.set_updated_at();

CREATE TRIGGER digital_cards_set_timestamps BEFORE INSERT OR UPDATE ON digital_cards FOR EACH ROW EXECUTE FUNCTION digital_cards_set_timestamps();

CREATE TRIGGER validate_card_media_reference_change BEFORE UPDATE OF photo_url, logo_url, cover_url ON digital_cards FOR EACH ROW EXECUTE FUNCTION private.validate_card_media_reference_change();

CREATE TRIGGER validate_card_qr_settings_change BEFORE UPDATE OF qr_settings ON digital_cards FOR EACH ROW EXECUTE FUNCTION private.validate_card_qr_settings_change();

alter table public."plans" enable row level security;
alter table public."organizations" enable row level security;
alter table public."organization_members" enable row level security;
alter table public."organization_subscriptions" enable row level security;
alter table public."digital_cards" enable row level security;

create policy "Authenticated users read active plans"
on public."plans"
as permissive
for select
to "authenticated"
using ((status = 'active'::text));

create policy "Members read their organizations"
on public."organizations"
as permissive
for select
to "authenticated"
using (private.is_organization_member(id));

create policy "Members read organization memberships"
on public."organization_members"
as permissive
for select
to "authenticated"
using (private.is_organization_member(organization_id));

create policy "Members read organization subscriptions"
on public."organization_subscriptions"
as permissive
for select
to "authenticated"
using (private.is_organization_member(organization_id));

create policy "Organization members read digital cards"
on public."digital_cards"
as permissive
for select
to "authenticated"
using (((organization_id IS NOT NULL) AND private.is_organization_member(organization_id)));

create policy "Owners read their digital cards"
on public."digital_cards"
as permissive
for select
to "authenticated"
using (((( SELECT auth.uid() AS uid) IS NOT NULL) AND (owner_id = ( SELECT auth.uid() AS uid))));

create policy "Public reads published cards"
on public."digital_cards"
as permissive
for select
to "anon", "authenticated"
using ((status = 'published'::text));

-- ACL efectivas de tablas para roles de aplicación.
revoke all privileges
on table public.organizations,
         public.organization_members,
         public.organization_subscriptions,
         public.plans,
         public.digital_cards
from public, anon, authenticated, service_role;

grant select on table public.digital_cards to anon, authenticated;
grant select on table public.organizations,
                      public.organization_members,
                      public.organization_subscriptions,
                      public.plans
to authenticated;

grant select, references, trigger, truncate, maintain
on table public.digital_cards
to service_role;

grant references, trigger, truncate, maintain
on table public.organizations,
         public.organization_members,
         public.organization_subscriptions,
         public.plans
to service_role;

grant select (id, name)
on table public.organizations
to service_role;

revoke all on function private.set_updated_at() from public, anon, authenticated, service_role;
revoke all on function private.qr_relative_luminance(text) from public, anon, authenticated, service_role;
revoke all on function private.qr_contrast_ratio(text, text) from public, anon, authenticated, service_role;
revoke all on function private.is_organization_member(uuid) from public, anon, authenticated, service_role;
revoke all on function private.has_organization_role(uuid, text[]) from public, anon, authenticated, service_role;
revoke all on function private.get_effective_plan(uuid) from public, anon, authenticated, service_role;
revoke all on function private.ensure_organization_has_active_owner() from public, anon, authenticated, service_role;
revoke all on function private.validate_card_media_reference_change() from public, anon, authenticated, service_role;
revoke all on function private.validate_card_qr_settings_change() from public, anon, authenticated, service_role;
revoke all on function public.digital_cards_set_timestamps() from public, anon, authenticated, service_role;
revoke all on function public.create_organization_card(uuid, text, text, text, text, text, text, text, text, text, text, text, boolean) from public, anon, authenticated, service_role;
revoke all on function public.update_organization_card(uuid, text, text, text, text, text, text, text, text, text, text, boolean) from public, anon, authenticated, service_role;
revoke all on function public.set_card_status(uuid, text) from public, anon, authenticated, service_role;

grant execute on function private.is_organization_member(uuid) to authenticated;
grant execute on function private.has_organization_role(uuid, text[]) to authenticated;

grant execute on function public.create_organization_card(
  uuid, text, text, text, text, text, text, text, text, text, text, text, boolean
) to authenticated;

grant execute on function public.update_organization_card(
  uuid, text, text, text, text, text, text, text, text, text, text, boolean
) to authenticated;

grant execute on function public.set_card_status(uuid, text) to authenticated;

commit;
