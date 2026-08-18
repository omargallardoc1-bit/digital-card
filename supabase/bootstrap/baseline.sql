-- Baseline reproducible de Digital Card para una instalación Supabase vacía.
-- Generada exclusivamente desde las snapshots de estado actual versionadas.
-- NO debe aplicarse sobre producción ni sobre un proyecto con objetos de la aplicación.
--
-- PostgreSQL no expone de forma confiable el project ref de Supabase a SQL.
-- Por ello no se inventa una comprobación contra loovwrnifdimlwpfgjza.
-- El instalador externo/CI DEBE bloquear ese project ref. Las comprobaciones
-- de objetos, bucket e historial siguientes son la barrera SQL adicional.

begin;

DO $baseline_preflight$
DECLARE
  existing_object text;
BEGIN
  IF to_regnamespace('auth') IS NULL
     OR to_regnamespace('storage') IS NULL
     OR to_regnamespace('extensions') IS NULL
  THEN
    RAISE EXCEPTION
      'La baseline requiere un proyecto Supabase inicializado con auth, storage y extensions.';
  END IF;

  IF to_regrole('anon') IS NULL
     OR to_regrole('authenticated') IS NULL
     OR to_regrole('service_role') IS NULL
  THEN
    RAISE EXCEPTION
      'La baseline requiere los roles administrados anon, authenticated y service_role.';
  END IF;

  IF to_regprocedure('storage.allow_any_operation(text[])') IS NULL
     OR to_regprocedure('storage.foldername(text)') IS NULL
     OR to_regprocedure('storage.filename(text)') IS NULL
  THEN
    RAISE EXCEPTION
      'La baseline requiere los helpers administrados de Supabase Storage.';
  END IF;

  SELECT candidate.object_name
  INTO existing_object
  FROM unnest(ARRAY[
    'public.plans',
    'public.organizations',
    'public.organization_members',
    'public.organization_subscriptions',
    'public.digital_cards',
    'public.card_events',
    'public.prospects',
    'public.card_buttons',
    'public.card_services',
    'public.card_socials',
    'public.organization_invitations'
  ]::text[]) AS candidate(object_name)
  WHERE to_regclass(candidate.object_name) IS NOT NULL
  LIMIT 1;

  IF existing_object IS NOT NULL THEN
    RAISE EXCEPTION
      'Baseline rechazada: ya existe la tabla principal %.', existing_object;
  END IF;

  SELECT candidate.object_name
  INTO existing_object
  FROM unnest(ARRAY[
    'public.create_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,text,boolean)',
    'public.update_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,boolean)',
    'public.set_card_status(uuid,text)',
    'public.list_organization_members(uuid)',
    'public.set_card_media_reference(uuid,text,text)',
    'public.set_card_qr_settings(uuid,text,text,boolean,numeric,text)',
    'public.create_public_prospect(uuid,text,text,text,text,boolean)',
    'public.get_organization_metrics(uuid,uuid,integer)',
    'public.list_organization_prospects(uuid,uuid,integer,integer,text)',
    'public.create_organization_invitation(uuid,text,text,bytea,timestamp with time zone,uuid)',
    'public.accept_organization_invitation(text)'
  ]::text[]) AS candidate(object_name)
  WHERE to_regprocedure(candidate.object_name) IS NOT NULL
  LIMIT 1;

  IF existing_object IS NOT NULL THEN
    RAISE EXCEPTION
      'Baseline rechazada: ya existe la RPC principal %.', existing_object;
  END IF;

  IF EXISTS (
    SELECT 1 FROM storage.buckets AS bucket
    WHERE bucket.id = 'digital-card-media'
  ) THEN
    RAISE EXCEPTION
      'Baseline rechazada: ya existe el bucket digital-card-media.';
  END IF;

  IF to_regclass('supabase_migrations.schema_migrations') IS NOT NULL THEN
    IF EXISTS (
      SELECT 1
      FROM supabase_migrations.schema_migrations AS migration
      WHERE migration.version IN (
        '20260814050818','20260814163620','20260814164045',
        '20260814180515','20260814184711','20260814190550',
        '20260814194735','20260814200953','20260814201752',
        '20260814205419','20260814212445','20260814222238',
        '20260814231522','20260815015327','20260815020534',
        '20260815205710','20260815210218','20260815210352',
        '20260817141457','20260817142512','20260817143043',
        '20260817143820','20260817144510','20260817145230'
      )
    ) THEN
      RAISE EXCEPTION
        'Baseline rechazada: existe historial de migraciones de Digital Card.';
    END IF;
  END IF;
END;
$baseline_preflight$;

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

DO $pgcrypto_preflight$
BEGIN
  IF to_regprocedure('extensions.digest(bytea,text)') IS NULL THEN
    RAISE EXCEPTION
      'pgcrypto no expone extensions.digest(bytea,text) en el schema extensions.';
  END IF;
END;
$pgcrypto_preflight$;


-- 3A — Núcleo de organizaciones y tarjetas
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


-- Función adicional extraída fielmente de producción.
CREATE OR REPLACE FUNCTION private.organization_role(target_organization_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
 select member.role from public.organization_members member
 where member.organization_id=target_organization_id and member.user_id=(select auth.uid()) and member.status='active' limit 1;
$function$;

-- 3D — Miembros, roles y límites
do $preconditions$
begin
  if to_regclass('public.organizations') is null
     or to_regclass('public.organization_members') is null
     or to_regclass('public.organization_subscriptions') is null
     or to_regclass('public.plans') is null
  then
    raise exception
      'Fase 3D requiere las tablas del núcleo organizacional versionadas en 3A.';
  end if;

  if to_regprocedure('private.get_effective_plan(uuid)') is null
     or to_regprocedure('private.is_organization_member(uuid)') is null
     or to_regprocedure('private.set_updated_at()') is null
     or to_regprocedure('private.ensure_organization_has_active_owner()') is null
  then
    raise exception
      'Fase 3D requiere los helpers organizacionales versionados en 3A.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_definition
    where constraint_definition.conrelid =
          'public.organization_members'::regclass
      and constraint_definition.conname = 'organization_members_pkey'
      and constraint_definition.contype = 'p'
  )
  or not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_definition
    where constraint_definition.conrelid =
          'public.organization_members'::regclass
      and constraint_definition.conname = 'organization_members_role_check'
      and constraint_definition.contype = 'c'
  )
  or not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_definition
    where constraint_definition.conrelid =
          'public.organization_members'::regclass
      and constraint_definition.conname = 'organization_members_status_check'
      and constraint_definition.contype = 'c'
  )
  or not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_definition
    where constraint_definition.conrelid =
          'public.organization_members'::regclass
      and constraint_definition.conname =
          'organization_members_timestamps_check'
      and constraint_definition.contype = 'c'
  )
  then
    raise exception
      'Fase 3D requiere los constraints de organization_members versionados en 3A.';
  end if;

  if to_regclass('public.organization_members_active_org_idx') is null
     or to_regclass('public.organization_members_active_user_idx') is null
     or to_regclass('public.organization_members_user_id_idx') is null
  then
    raise exception
      'Fase 3D requiere los índices de organization_members versionados en 3A.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_trigger as trigger_definition
    where trigger_definition.tgrelid = 'public.organization_members'::regclass
      and trigger_definition.tgname =
          'organization_members_require_active_owner'
      and not trigger_definition.tgisinternal
  )
  or not exists (
    select 1
    from pg_catalog.pg_trigger as trigger_definition
    where trigger_definition.tgrelid = 'public.organization_members'::regclass
      and trigger_definition.tgname = 'organization_members_set_updated_at'
      and not trigger_definition.tgisinternal
  )
  then
    raise exception
      'Fase 3D requiere los triggers de organization_members versionados en 3A.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policies as policy_definition
    where policy_definition.schemaname = 'public'
      and policy_definition.tablename = 'organization_members'
      and policy_definition.policyname =
          'Members read organization memberships'
      and policy_definition.cmd = 'SELECT'
  )
  then
    raise exception
      'Fase 3D requiere la policy de lectura de organization_members versionada en 3A.';
  end if;
end;
$preconditions$;

CREATE OR REPLACE FUNCTION private.lock_member_plan_context(target_organization_id uuid, require_expansion boolean)
 RETURNS TABLE(commercial_status text, max_members integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  initial_effective_plan record;
  locked_organization_status text;
  locked_subscription record;
  locked_plan record;
  diagnostic_subscription record;
  active_member_count bigint;
  resolved_status text;
  resolved_max_members integer;
begin
  if target_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'La organización es obligatoria.';
  end if;

  /*
   * La lectura es no bloqueante. Solo identifica los IDs definidos por
   * private.get_effective_plan(); no toma una decisión comercial final.
   */
  if coalesce(require_expansion, false) then
    select *
      into initial_effective_plan
    from private.get_effective_plan(target_organization_id);
  end if;

  /*
   * Orden global:
   * organización → suscripción → plan → membresía.
   */
  select organization.status
    into locked_organization_status
  from public.organizations as organization
  where organization.id = target_organization_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La organización no existe.';
  end if;

  if locked_organization_status <> 'active' then
    raise exception using
      errcode = '42501',
      message = 'La organización no está activa.';
  end if;

  if coalesce(require_expansion, false) then
    if initial_effective_plan.subscription_id is null
       or initial_effective_plan.plan_id is null
    then
      raise exception using
        errcode = '42501',
        message =
          'La suscripción actual no permite agregar o reactivar miembros.';
    end if;

    /*
     * Se bloquea exactamente la suscripción identificada por
     * private.get_effective_plan().
     */
    select
      subscription.id,
      subscription.organization_id,
      subscription.plan_id,
      subscription.status,
      subscription.starts_at,
      subscription.expires_at
    into locked_subscription
    from public.organization_subscriptions as subscription
    where subscription.id = initial_effective_plan.subscription_id
      and subscription.organization_id = target_organization_id
    for update;

    if not found
       or locked_subscription.plan_id
          is distinct from initial_effective_plan.plan_id
       or locked_subscription.status not in ('trial', 'active')
       or locked_subscription.starts_at > now()
       or (
         locked_subscription.expires_at is not null
         and locked_subscription.expires_at <= now()
       )
    then
      raise exception using
        errcode = '42501',
        message =
          'La suscripción actual no permite agregar o reactivar miembros.';
    end if;

    select
      plan.id,
      plan.status,
      plan.max_members
    into locked_plan
    from public.plans as plan
    where plan.id = initial_effective_plan.plan_id
    for share;

    if not found
       or locked_plan.status <> 'active'
       or locked_plan.max_members is null
       or locked_plan.max_members <= 0
    then
      raise exception using
        errcode = '42501',
        message =
          'La suscripción actual no permite agregar o reactivar miembros.';
    end if;

    /*
     * Revalidación adicional: el contexto efectivo sigue apuntando a
     * las mismas filas que fueron bloqueadas.
     */
    if not exists (
      select 1
      from private.get_effective_plan(target_organization_id)
        as effective
      where effective.subscription_id = locked_subscription.id
        and effective.plan_id = locked_plan.id
        and effective.subscription_status in ('trial', 'active')
    ) then
      raise exception using
        errcode = '40001',
        message =
          'La suscripción cambió durante la operación. Intenta nuevamente.';
    end if;

    select count(*)
      into active_member_count
    from public.organization_members as member
    where member.organization_id = target_organization_id
      and member.status = 'active';

    if active_member_count >= locked_plan.max_members then
      raise exception using
        errcode = 'P0001',
        message = 'Has alcanzado el límite de miembros de tu plan.';
    end if;

    resolved_status := locked_subscription.status;
    resolved_max_members := locked_plan.max_members;
  else
    /*
     * Las reducciones no requieren plan efectivo. Primero se intenta
     * identificar el contexto efectivo canónico.
     */
    select *
      into initial_effective_plan
    from private.get_effective_plan(target_organization_id);

    if initial_effective_plan.subscription_id is not null
       and initial_effective_plan.plan_id is not null
    then
      select
        subscription.id,
        subscription.organization_id,
        subscription.plan_id,
        subscription.status,
        subscription.starts_at,
        subscription.expires_at
      into locked_subscription
      from public.organization_subscriptions as subscription
      where subscription.id = initial_effective_plan.subscription_id
        and subscription.organization_id = target_organization_id
      for update;

      if found then
        select
          plan.id,
          plan.status,
          plan.max_members
        into locked_plan
        from public.plans as plan
        where plan.id = locked_subscription.plan_id
        for share;
      end if;

      if locked_subscription.id is not null
         and locked_plan.id is not null
         and locked_plan.status = 'active'
         and locked_subscription.status
             in ('trial', 'active', 'past_due')
         and locked_subscription.starts_at <= now()
         and (
           locked_subscription.expires_at is null
           or locked_subscription.expires_at > now()
         )
      then
        resolved_status := locked_subscription.status;
        resolved_max_members := locked_plan.max_members;
      end if;
    end if;

    /*
     * Esta selección solo clasifica un estado no efectivo para UI y
     * reglas reductoras. Nunca concede capacidad ni max_members.
     */
    if resolved_status is null then
      select
        subscription.id,
        subscription.plan_id,
        subscription.status,
        subscription.starts_at,
        subscription.expires_at
      into diagnostic_subscription
      from public.organization_subscriptions as subscription
      where subscription.organization_id = target_organization_id
      order by
        subscription.starts_at desc,
        subscription.created_at desc,
        subscription.id desc
      limit 1
      for update;

      if not found then
        resolved_status := 'no_subscription';
        resolved_max_members := null;
      else
        select
          plan.id,
          plan.status,
          plan.max_members
        into locked_plan
        from public.plans as plan
        where plan.id = diagnostic_subscription.plan_id
        for share;

        resolved_max_members := null;

        if locked_plan.id is null
           or locked_plan.status <> 'active'
        then
          resolved_status := 'plan_inactive';
        elsif diagnostic_subscription.status = 'cancelled' then
          resolved_status := 'cancelled';
        elsif diagnostic_subscription.status = 'expired'
           or (
             diagnostic_subscription.expires_at is not null
             and diagnostic_subscription.expires_at <= now()
           )
        then
          resolved_status := 'expired';
        elsif diagnostic_subscription.starts_at > now() then
          resolved_status := 'not_started';
        elsif diagnostic_subscription.status = 'past_due' then
          resolved_status := 'past_due';
        else
          /*
           * Si aparentemente debería ser efectiva pero el helper canónico
           * no la seleccionó, no se concede capacidad.
           */
          resolved_status := 'no_subscription';
        end if;
      end if;
    end if;
  end if;

  return query
  select resolved_status, resolved_max_members;
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_organization_members(target_organization_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  caller_role text;
  effective_plan record;
  diagnostic_subscription record;
  diagnostic_plan record;
  active_count bigint;
  members_json jsonb;
  resolved_status text;
  resolved_max_members integer;
begin
  current_user_id := auth.uid();

  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  select member.role
    into caller_role
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = current_user_id
    and member.status = 'active';

  if not found then
    raise exception using
      errcode = '42501',
      message = 'No tienes acceso a esta organización.';
  end if;

  select *
    into effective_plan
  from private.get_effective_plan(target_organization_id);

  if effective_plan.subscription_id is not null then
    resolved_status := effective_plan.subscription_status;
    resolved_max_members := effective_plan.max_members;
  else
    /*
     * Diagnóstico explícito de una suscripción no efectiva.
     * max_members permanece NULL porque no representa capacidad vigente.
     */
    select
      subscription.id,
      subscription.plan_id,
      subscription.status,
      subscription.starts_at,
      subscription.expires_at
    into diagnostic_subscription
    from public.organization_subscriptions as subscription
    where subscription.organization_id = target_organization_id
    order by
      subscription.starts_at desc,
      subscription.created_at desc,
      subscription.id desc
    limit 1;

    resolved_max_members := null;

    if not found then
      resolved_status := 'no_subscription';
    else
      select
        plan.id,
        plan.status
      into diagnostic_plan
      from public.plans as plan
      where plan.id = diagnostic_subscription.plan_id;

      if diagnostic_plan.id is null
         or diagnostic_plan.status <> 'active'
      then
        resolved_status := 'plan_inactive';
      elsif diagnostic_subscription.status = 'cancelled' then
        resolved_status := 'cancelled';
      elsif diagnostic_subscription.status = 'expired'
         or (
           diagnostic_subscription.expires_at is not null
           and diagnostic_subscription.expires_at <= now()
         )
      then
        resolved_status := 'expired';
      elsif diagnostic_subscription.starts_at > now() then
        resolved_status := 'not_started';
      elsif diagnostic_subscription.status = 'past_due' then
        resolved_status := 'past_due';
      else
        resolved_status := 'no_subscription';
      end if;
    end if;
  end if;

  select count(*)
    into active_count
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.status = 'active';

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',
          case
            when caller_role in ('owner', 'admin')
              or member.user_id = current_user_id
            then to_jsonb(member.user_id)
            else 'null'::jsonb
          end,
        'email',
          case
            when caller_role in ('owner', 'admin')
            then to_jsonb(auth_user.email)
            else 'null'::jsonb
          end,
        'role', member.role,
        'status', member.status,
        'created_at', member.created_at,
        'updated_at', member.updated_at,
        'is_current_user', member.user_id = current_user_id
      )
      order by
        case member.role
          when 'owner' then 1
          when 'admin' then 2
          when 'editor' then 3
          when 'viewer' then 4
        end,
        member.created_at,
        member.user_id
    ),
    '[]'::jsonb
  )
  into members_json
  from public.organization_members as member
  join auth.users as auth_user
    on auth_user.id = member.user_id
  where member.organization_id = target_organization_id;

  return jsonb_build_object(
    'items', members_json,
    'active_count', active_count,
    'max_members', resolved_max_members,
    'effective_subscription_status',
      coalesce(resolved_status, 'no_subscription'),
    'caller_role', caller_role,
    'can_manage', caller_role in ('owner', 'admin')
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.add_organization_member_by_email(target_organization_id uuid, member_email text, member_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  caller_role text;
  normalized_email text;
  normalized_role text;
  target_auth_user_id uuid;
  eligible_user_count bigint;
  existing_member public.organization_members%rowtype;
  inserted_member public.organization_members%rowtype;
begin
  current_user_id := auth.uid();

  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  normalized_email := lower(btrim(coalesce(member_email, '')));
  normalized_role := lower(btrim(coalesce(member_role, '')));

  if normalized_email = ''
     or char_length(normalized_email) > 320
     or normalized_email !~
       '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  then
    raise exception using
      errcode = '22023',
      message = 'La cuenta indicada no existe o no es elegible.';
  end if;

  if normalized_role not in ('owner', 'admin', 'editor', 'viewer') then
    raise exception using
      errcode = '22023',
      message = 'El rol solicitado no es válido.';
  end if;

  select member.role
    into caller_role
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = current_user_id
    and member.status = 'active';

  if caller_role is null
     or caller_role not in ('owner', 'admin')
  then
    raise exception using
      errcode = '42501',
      message = 'No tienes permiso para administrar miembros.';
  end if;

  if caller_role = 'admin'
     and normalized_role = 'owner'
  then
    raise exception using
      errcode = '42501',
      message = 'Un administrador no puede crear owners.';
  end if;

  perform *
  from private.lock_member_plan_context(
    target_organization_id,
    true
  );

  select
    count(*),
    (array_agg(auth_user.id order by auth_user.id))[1]
  into
    eligible_user_count,
    target_auth_user_id
  from auth.users as auth_user
  where lower(btrim(auth_user.email)) = normalized_email
    and auth_user.deleted_at is null
    and auth_user.is_anonymous is false
    and coalesce(
      auth_user.email_confirmed_at,
      auth_user.confirmed_at
    ) is not null
    and (
      auth_user.banned_until is null
      or auth_user.banned_until <= now()
    );

  if eligible_user_count <> 1
     or target_auth_user_id is null
  then
    raise exception using
      errcode = 'P0001',
      message = 'La cuenta indicada no existe o no es elegible.';
  end if;

  select *
    into existing_member
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_auth_user_id
  for update;

  if found then
    raise exception using
      errcode = '23505',
      message = 'La cuenta indicada no existe o no es elegible.';
  end if;

  insert into public.organization_members (
    organization_id,
    user_id,
    role,
    status,
    created_by
  )
  values (
    target_organization_id,
    target_auth_user_id,
    normalized_role,
    'active',
    current_user_id
  )
  returning *
    into inserted_member;

  return jsonb_build_object(
    'user_id', inserted_member.user_id,
    'role', inserted_member.role,
    'status', inserted_member.status,
    'created_at', inserted_member.created_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_organization_member(target_organization_id uuid, target_user_id uuid, new_role text, new_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  caller_role text;
  initial_target_role text;
  initial_target_status text;
  normalized_role text;
  normalized_status text;
  requires_expansion boolean;
  commercial_context record;
  locked_target public.organization_members%rowtype;
  updated_member public.organization_members%rowtype;
  other_active_owner_count bigint;
begin
  current_user_id := auth.uid();

  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  if target_organization_id is null
     or target_user_id is null
  then
    raise exception using
      errcode = '22023',
      message = 'La organización y el miembro son obligatorios.';
  end if;

  normalized_role := lower(btrim(coalesce(new_role, '')));
  normalized_status := lower(btrim(coalesce(new_status, '')));

  if normalized_role not in ('owner', 'admin', 'editor', 'viewer')
     or normalized_status not in ('active', 'disabled')
  then
    raise exception using
      errcode = '22023',
      message = 'El rol o estado solicitado no es válido.';
  end if;

  select member.role
    into caller_role
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = current_user_id
    and member.status = 'active';

  if caller_role is null
     or caller_role not in ('owner', 'admin')
  then
    raise exception using
      errcode = '42501',
      message = 'No tienes permiso para administrar miembros.';
  end if;

  /*
   * Lectura no bloqueante para determinar si la operación aumenta
   * active_count. La fila se revalida después de los locks comerciales.
   */
  select member.role, member.status
    into initial_target_role, initial_target_status
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'El miembro no existe.';
  end if;

  if caller_role = 'admin'
     and (
       target_user_id = current_user_id
       or initial_target_role = 'owner'
       or normalized_role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message = 'Un administrador no puede realizar ese cambio.';
  end if;

  requires_expansion :=
    initial_target_status = 'disabled'
    and normalized_status = 'active';

  select *
    into commercial_context
  from private.lock_member_plan_context(
    target_organization_id,
    requires_expansion
  );

  /*
   * El lock de membership se adquiere después de organización,
   * suscripción y plan.
   */
  select *
    into locked_target
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id
  for update;

  if not found
     or locked_target.role is distinct from initial_target_role
     or locked_target.status is distinct from initial_target_status
  then
    raise exception using
      errcode = '40001',
      message =
        'La membresía cambió durante la operación. Intenta nuevamente.';
  end if;

  /*
   * Cambios de rol que no alteran active_count:
   * trial/active/past_due sí; estados no efectivos no.
   *
   * Deshabilitar sigue siendo una reducción válida en cualquier estado.
   */
  if locked_target.status = 'active'
     and normalized_status = 'active'
     and normalized_role is distinct from locked_target.role
     and commercial_context.commercial_status
         not in ('trial', 'active', 'past_due')
  then
    raise exception using
      errcode = '42501',
      message = 'La suscripción actual no permite cambiar roles.';
  end if;

  if locked_target.role = 'owner'
     and locked_target.status = 'active'
     and (
       normalized_role <> 'owner'
       or normalized_status <> 'active'
     )
  then
    select count(*)
      into other_active_owner_count
    from public.organization_members as member
    where member.organization_id = target_organization_id
      and member.user_id <> target_user_id
      and member.role = 'owner'
      and member.status = 'active';

    if other_active_owner_count = 0 then
      raise exception using
        errcode = '23514',
        message = 'No puedes modificar al último owner activo.';
    end if;
  end if;

  update public.organization_members as member
  set
    role = normalized_role,
    status = normalized_status,
    updated_at = now()
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id
  returning *
    into updated_member;

  return jsonb_build_object(
    'user_id', updated_member.user_id,
    'role', updated_member.role,
    'status', updated_member.status,
    'updated_at', updated_member.updated_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.remove_organization_member(target_organization_id uuid, target_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  caller_role text;
  initial_target_role text;
  initial_target_status text;
  locked_target public.organization_members%rowtype;
  other_active_owner_count bigint;
begin
  current_user_id := auth.uid();

  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  if target_organization_id is null
     or target_user_id is null
  then
    raise exception using
      errcode = '22023',
      message = 'La organización y el miembro son obligatorios.';
  end if;

  select member.role
    into caller_role
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = current_user_id
    and member.status = 'active';

  if caller_role is null
     or caller_role not in ('owner', 'admin')
  then
    raise exception using
      errcode = '42501',
      message = 'No tienes permiso para administrar miembros.';
  end if;

  select member.role, member.status
    into initial_target_role, initial_target_status
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'El miembro no existe.';
  end if;

  if caller_role = 'admin'
     and (
       target_user_id = current_user_id
       or initial_target_role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message = 'Un administrador no puede eliminar esa membresía.';
  end if;

  /*
   * require_expansion=false permite eliminar aunque no exista
   * suscripción efectiva.
   */
  perform *
  from private.lock_member_plan_context(
    target_organization_id,
    false
  );

  select *
    into locked_target
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id
  for update;

  if not found
     or locked_target.role is distinct from initial_target_role
     or locked_target.status is distinct from initial_target_status
  then
    raise exception using
      errcode = '40001',
      message =
        'La membresía cambió durante la operación. Intenta nuevamente.';
  end if;

  if locked_target.role = 'owner'
     and locked_target.status = 'active'
  then
    select count(*)
      into other_active_owner_count
    from public.organization_members as member
    where member.organization_id = target_organization_id
      and member.user_id <> target_user_id
      and member.role = 'owner'
      and member.status = 'active';

    if other_active_owner_count = 0 then
      raise exception using
        errcode = '23514',
        message = 'No puedes eliminar al último owner activo.';
    end if;
  end if;

  delete from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id;

  return jsonb_build_object(
    'removed', true,
    'user_id', target_user_id
  );
end;
$function$;


-- 3B — Media, Storage y QR
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


-- 3C — Prospectos, eventos y métricas
do $preconditions$
begin
  if to_regclass('public.digital_cards') is null
     or to_regclass('public.organizations') is null
     or to_regclass('public.organization_members') is null
     or to_regclass('public.organization_subscriptions') is null
     or to_regclass('public.plans') is null then
    raise exception 'Falta el núcleo organizacional versionado en la Fase 3A.';
  end if;

  if to_regprocedure('private.get_effective_plan(uuid)') is null then
    raise exception 'Falta private.get_effective_plan(uuid) de la Fase 3A.';
  end if;
end;
$preconditions$;

create table public."card_events" (
  "id" uuid default gen_random_uuid() not null,
  "card_id" uuid not null,
  "event_type" text not null,
  "created_at" timestamp with time zone default now(),
  "metadata" jsonb default '{}'::jsonb not null,
  constraint "card_events_card_id_fkey" FOREIGN KEY (card_id) REFERENCES digital_cards(id) ON DELETE CASCADE,
  constraint "card_events_event_type_check" CHECK (event_type = ANY (ARRAY['view'::text, 'whatsapp_click'::text, 'call_click'::text, 'email_click'::text, 'website_click'::text, 'lead_created'::text])),
  constraint "card_events_pkey" PRIMARY KEY (id)
);

create table public."prospects" (
  "id" uuid default gen_random_uuid() not null,
  "card_id" uuid not null,
  "name" text not null,
  "whatsapp" text not null,
  "email" text,
  "created_at" timestamp with time zone default now(),
  "source" text default 'public_card'::text not null,
  "consent_given" boolean default false not null,
  "consent_at" timestamp with time zone,
  "consent_version" text,
  constraint "prospects_card_id_fkey" FOREIGN KEY (card_id) REFERENCES digital_cards(id) ON DELETE CASCADE,
  constraint "prospects_consent_check" CHECK (consent_given = false AND consent_at IS NULL OR consent_given = true AND consent_at IS NOT NULL AND NULLIF(TRIM(BOTH FROM consent_version), ''::text) IS NOT NULL),
  constraint "prospects_pkey" PRIMARY KEY (id)
);

CREATE OR REPLACE FUNCTION private.lock_lead_capture_plan(target_organization_id uuid)
 RETURNS TABLE(subscription_id uuid, subscription_status text, plan_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  locked_organization_status text;
  locked_subscription_id uuid;
  locked_subscription_status text;
  locked_subscription_starts_at timestamptz;
  locked_subscription_expires_at timestamptz;
  locked_plan_id uuid;
  locked_plan_status text;
  locked_lead_capture_enabled boolean;
begin
  if target_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'La organización no es válida.';
  end if;

  select organization.status
  into locked_organization_status
  from public.organizations as organization
  where organization.id = target_organization_id
  for update;

  if not found
    or locked_organization_status <> 'active'
  then
    raise exception using
      errcode = 'P0001',
      message = 'La organización no está activa.';
  end if;

  select
    subscription.id,
    subscription.status,
    subscription.starts_at,
    subscription.expires_at,
    subscription.plan_id
  into
    locked_subscription_id,
    locked_subscription_status,
    locked_subscription_starts_at,
    locked_subscription_expires_at,
    locked_plan_id
  from public.organization_subscriptions as subscription
  where subscription.organization_id =
    target_organization_id
    and subscription.status in (
      'trial',
      'active',
      'past_due'
    )
  order by
    subscription.starts_at desc,
    subscription.created_at desc,
    subscription.id desc
  limit 1
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message =
        'La organización no tiene una suscripción utilizable.';
  end if;

  if locked_subscription_status not in (
    'trial',
    'active'
  ) then
    raise exception using
      errcode = 'P0001',
      message =
        'La captura no está disponible con el estado actual de la suscripción.';
  end if;

  if locked_subscription_starts_at > now() then
    raise exception using
      errcode = 'P0001',
      message = 'La suscripción todavía no está vigente.';
  end if;

  if locked_subscription_expires_at is not null
    and locked_subscription_expires_at <= now()
  then
    raise exception using
      errcode = 'P0001',
      message = 'La suscripción ha vencido.';
  end if;

  select
    plan.status,
    plan.lead_capture_enabled
  into
    locked_plan_status,
    locked_lead_capture_enabled
  from public.plans as plan
  where plan.id = locked_plan_id
  for update;

  if not found
    or locked_plan_status <> 'active'
  then
    raise exception using
      errcode = 'P0001',
      message = 'El plan no está activo.';
  end if;

  if locked_lead_capture_enabled is distinct from true then
    raise exception using
      errcode = 'P0001',
      message =
        'El plan no incluye captura de prospectos.';
  end if;

  return query
  select
    locked_subscription_id,
    locked_subscription_status,
    locked_plan_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.record_lead_created_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  insert into public.card_events (card_id, event_type, metadata)
  values (
    new.card_id,
    'lead_created',
    jsonb_build_object(
      'source', coalesce(nullif(btrim(new.source), ''), 'public_card')
    )
  );

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_public_prospect(target_card_id uuid, prospect_name text, prospect_phone text, prospect_email text DEFAULT NULL::text, prospect_source text DEFAULT 'public_card'::text, consent_given boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  normalized_name text;
  normalized_phone text;
  normalized_email text;
  normalized_source text;
  initial_organization_id uuid;
  locked_card record;
  locked_commercial_context record;
  inserted_prospect_id uuid;
begin
  normalized_name := btrim(coalesce(prospect_name, ''));
  normalized_phone := btrim(coalesce(prospect_phone, ''));
  normalized_email := nullif(
    btrim(coalesce(prospect_email, '')),
    ''
  );
  normalized_source := lower(
    btrim(coalesce(prospect_source, ''))
  );

  if target_card_id is null then
    raise exception using
      errcode = '22023',
      message = 'La tarjeta no es válida.';
  end if;

  if normalized_name = ''
    or char_length(normalized_name) > 120
    or normalized_name ~ '[[:cntrl:]]'
  then
    raise exception using
      errcode = '22023',
      message =
        'El nombre es obligatorio y debe tener máximo 120 caracteres.';
  end if;

  if char_length(normalized_phone) < 7
    or char_length(normalized_phone) > 40
    or normalized_phone !~ '^[0-9+(). -]+$'
  then
    raise exception using
      errcode = '22023',
      message = 'El teléfono no es válido.';
  end if;

  if normalized_email is not null
    and (
      char_length(normalized_email) > 254
      or normalized_email !~
        '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    )
  then
    raise exception using
      errcode = '22023',
      message = 'El correo no es válido.';
  end if;

  if normalized_source not in (
    'public_card',
    'qr'
  ) then
    raise exception using
      errcode = '22023',
      message = 'La fuente no es válida.';
  end if;

  if consent_given is distinct from true then
    raise exception using
      errcode = '22023',
      message = 'El consentimiento explícito es obligatorio.';
  end if;

  select card.organization_id
  into initial_organization_id
  from public.digital_cards as card
  where card.id = target_card_id;

  if not found
    or initial_organization_id is null
  then
    raise exception using
      errcode = 'P0001',
      message = 'La captura no está disponible.';
  end if;

  select commercial_context.*
  into locked_commercial_context
  from private.lock_lead_capture_plan(
    initial_organization_id
  ) as commercial_context;

  select
    card.id,
    card.organization_id,
    card.status,
    card.capture_enabled
  into locked_card
  from public.digital_cards as card
  where card.id = target_card_id
    and card.organization_id =
      initial_organization_id
  for share;

  if not found
    or locked_card.status <> 'published'
    or locked_card.capture_enabled is distinct from true
  then
    raise exception using
      errcode = 'P0001',
      message = 'La captura no está disponible.';
  end if;

  insert into public.prospects (
    card_id,
    name,
    whatsapp,
    email,
    source,
    consent_given,
    consent_at,
    consent_version
  )
  values (
    target_card_id,
    normalized_name,
    normalized_phone,
    normalized_email,
    normalized_source,
    true,
    now(),
    'v1'
  )
  returning id into inserted_prospect_id;

  return inserted_prospect_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_organization_metrics(target_organization_id uuid, target_card_id uuid DEFAULT NULL::uuid, requested_days integer DEFAULT NULL::integer)
 RETURNS TABLE(period_start timestamp with time zone, period_end timestamp with time zone, applied_days integer, views bigint, whatsapp_clicks bigint, calls bigint, emails bigint, website_clicks bigint, leads bigint, conversion_rate numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  effective_plan record;
  calculated_start timestamptz;
  calculated_end timestamptz := now();
  calculated_days integer;
  metric_views bigint;
  metric_whatsapp bigint;
  metric_calls bigint;
  metric_emails bigint;
  metric_web bigint;
  metric_leads bigint;
begin
  if (select auth.uid()) is null then
    raise exception using
      errcode = '42501',
      message = 'Se requiere autenticación.';
  end if;

  if target_organization_id is null
    or not exists (
      select 1
      from public.organization_members as member
      where member.organization_id =
        target_organization_id
        and member.user_id = (select auth.uid())
        and member.status = 'active'
    )
  then
    raise exception using
      errcode = '42501',
      message = 'No tienes acceso a esta organización.';
  end if;

  select plan_row.*
  into effective_plan
  from private.get_effective_plan(
    target_organization_id
  ) as plan_row;

  if not found then
    raise exception using
      errcode = 'P0001',
      message =
        'La organización no tiene una suscripción utilizable.';
  end if;

  if effective_plan.analytics_enabled
    is distinct from true
  then
    raise exception using
      errcode = '42501',
      message = 'El plan no incluye estadísticas.';
  end if;

  if requested_days is not null
    and requested_days <= 0
  then
    raise exception using
      errcode = '22023',
      message = 'El periodo solicitado no es válido.';
  end if;

  if effective_plan.analytics_history_days is null then
    calculated_days := requested_days;
  elsif requested_days is null then
    calculated_days :=
      effective_plan.analytics_history_days;
  else
    calculated_days := least(
      requested_days,
      effective_plan.analytics_history_days
    );
  end if;

  if calculated_days is not null then
    calculated_start :=
      calculated_end
      - make_interval(days => calculated_days);
  else
    calculated_start := null;
  end if;

  if target_card_id is not null
    and not exists (
      select 1
      from public.digital_cards as card
      where card.id = target_card_id
        and card.organization_id =
          target_organization_id
    )
  then
    raise exception using
      errcode = '22023',
      message =
        'La tarjeta no pertenece a la organización.';
  end if;

  select
    count(*) filter (
      where event.event_type = 'view'
    ),
    count(*) filter (
      where event.event_type = 'whatsapp_click'
    ),
    count(*) filter (
      where event.event_type = 'call_click'
    ),
    count(*) filter (
      where event.event_type = 'email_click'
    ),
    count(*) filter (
      where event.event_type = 'website_click'
    ),
    count(*) filter (
      where event.event_type = 'lead_created'
    )
  into
    metric_views,
    metric_whatsapp,
    metric_calls,
    metric_emails,
    metric_web,
    metric_leads
  from public.card_events as event
  join public.digital_cards as card
    on card.id = event.card_id
  where card.organization_id =
    target_organization_id
    and (
      target_card_id is null
      or card.id = target_card_id
    )
    and (
      calculated_start is null
      or event.created_at >= calculated_start
    )
    and event.created_at <= calculated_end;

  return query
  select
    calculated_start,
    calculated_end,
    calculated_days,
    coalesce(metric_views, 0),
    coalesce(metric_whatsapp, 0),
    coalesce(metric_calls, 0),
    coalesce(metric_emails, 0),
    coalesce(metric_web, 0),
    coalesce(metric_leads, 0),
    case
      when coalesce(metric_views, 0) = 0 then 0::numeric
      else round(
        metric_leads::numeric
        / metric_views::numeric
        * 100,
        2
      )
    end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_organization_prospects(target_organization_id uuid, target_card_id uuid DEFAULT NULL::uuid, requested_page integer DEFAULT 1, requested_page_size integer DEFAULT 50, sort_direction text DEFAULT 'desc'::text)
 RETURNS TABLE(items jsonb, total_count bigint, page_number integer, page_size integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  effective_plan record;
  normalized_sort text;
  safe_page integer;
  safe_page_size integer;
  row_offset integer;
  matching_count bigint;
  result_items jsonb;
begin
  if (select auth.uid()) is null then
    raise exception using
      errcode = '42501',
      message = 'Se requiere autenticación.';
  end if;

  if target_organization_id is null
    or not exists (
      select 1
      from public.organization_members as member
      where member.organization_id =
        target_organization_id
        and member.user_id = (select auth.uid())
        and member.status = 'active'
        and member.role in (
          'owner',
          'admin',
          'editor'
        )
    )
  then
    raise exception using
      errcode = '42501',
      message =
        'No tienes permiso para consultar prospectos.';
  end if;

  select plan_row.*
  into effective_plan
  from private.get_effective_plan(
    target_organization_id
  ) as plan_row;

  if not found then
    raise exception using
      errcode = 'P0001',
      message =
        'La organización no tiene una suscripción utilizable.';
  end if;

  if target_card_id is not null
    and not exists (
      select 1
      from public.digital_cards as card
      where card.id = target_card_id
        and card.organization_id =
          target_organization_id
    )
  then
    raise exception using
      errcode = '22023',
      message =
        'La tarjeta no pertenece a la organización.';
  end if;

  safe_page := greatest(coalesce(requested_page, 1), 1);
  safe_page_size := least(
    greatest(coalesce(requested_page_size, 50), 1),
    100
  );

  if safe_page > 100000 then
    raise exception using
      errcode = '22023',
      message = 'La página solicitada no es válida.';
  end if;

  normalized_sort := lower(
    btrim(coalesce(sort_direction, 'desc'))
  );

  if normalized_sort not in ('asc', 'desc') then
    raise exception using
      errcode = '22023',
      message = 'El orden solicitado no es válido.';
  end if;

  row_offset := (safe_page - 1) * safe_page_size;

  select count(*)
  into matching_count
  from public.prospects as prospect
  join public.digital_cards as card
    on card.id = prospect.card_id
  where card.organization_id =
    target_organization_id
    and (
      target_card_id is null
      or card.id = target_card_id
    );

  if normalized_sort = 'asc' then
    select coalesce(
      jsonb_agg(
        page_row.item
        order by
          page_row.created_at asc,
          page_row.prospect_id asc
      ),
      '[]'::jsonb
    )
    into result_items
    from (
      select
        prospect.created_at,
        prospect.id as prospect_id,
        jsonb_build_object(
          'id', prospect.id,
          'card_id', prospect.card_id,
          'name', prospect.name,
          'phone', prospect.whatsapp,
          'email', prospect.email,
          'card_name', card.name,
          'created_at', prospect.created_at,
          'source', prospect.source,
          'consent_given', prospect.consent_given,
          'consent_at', prospect.consent_at,
          'consent_version', prospect.consent_version
        ) as item
      from public.prospects as prospect
      join public.digital_cards as card
        on card.id = prospect.card_id
      where card.organization_id =
        target_organization_id
        and (
          target_card_id is null
          or card.id = target_card_id
        )
      order by
        prospect.created_at asc,
        prospect.id asc
      limit safe_page_size
      offset row_offset
    ) as page_row;
  else
    select coalesce(
      jsonb_agg(
        page_row.item
        order by
          page_row.created_at desc,
          page_row.prospect_id desc
      ),
      '[]'::jsonb
    )
    into result_items
    from (
      select
        prospect.created_at,
        prospect.id as prospect_id,
        jsonb_build_object(
          'id', prospect.id,
          'card_id', prospect.card_id,
          'name', prospect.name,
          'phone', prospect.whatsapp,
          'email', prospect.email,
          'card_name', card.name,
          'created_at', prospect.created_at,
          'source', prospect.source,
          'consent_given', prospect.consent_given,
          'consent_at', prospect.consent_at,
          'consent_version', prospect.consent_version
        ) as item
      from public.prospects as prospect
      join public.digital_cards as card
        on card.id = prospect.card_id
      where card.organization_id =
        target_organization_id
        and (
          target_card_id is null
          or card.id = target_card_id
        )
      order by
        prospect.created_at desc,
        prospect.id desc
      limit safe_page_size
      offset row_offset
    ) as page_row;
  end if;

  return query
  select
    result_items,
    matching_count,
    safe_page,
    safe_page_size;
end;
$function$;

CREATE INDEX card_events_card_created_type_idx ON public.card_events USING btree (card_id, created_at DESC, event_type);

CREATE INDEX card_events_card_id_created_at_idx ON public.card_events USING btree (card_id, created_at DESC);

CREATE INDEX prospects_card_id_created_at_idx ON public.prospects USING btree (card_id, created_at DESC);

CREATE INDEX prospects_created_at_id_idx ON public.prospects USING btree (created_at DESC, id DESC, card_id);

CREATE TRIGGER prospects_record_lead_created_event AFTER INSERT ON prospects FOR EACH ROW EXECUTE FUNCTION record_lead_created_event();

alter table public."card_events" enable row level security;
alter table public."prospects" enable row level security;

create policy "Owners delete prospects"
on public."prospects"
as permissive
for delete
to "authenticated"
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = prospects.card_id) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))
;


-- 3E — Componentes de tarjetas
do $preconditions$
begin
  if to_regclass('public.digital_cards') is null
     or to_regclass('public.organizations') is null
     or to_regclass('public.organization_members') is null
  then
    raise exception
      'Fase 3E requiere el núcleo organizacional y digital_cards versionado en 3A.';
  end if;

  if to_regprocedure('private.is_organization_member(uuid)') is null
     or to_regprocedure('private.has_organization_role(uuid,text[])') is null
  then
    raise exception
      'Fase 3E requiere los helpers de autorización versionados en 3A.';
  end if;
end;
$preconditions$;

create table public.card_buttons (
  id uuid default gen_random_uuid() not null,
  card_id uuid not null,
  label text not null,
  action_type text not null,
  action_value text not null,
  "position" integer default 0,
  enabled boolean default true,
  created_at timestamp with time zone default now(),
  constraint card_buttons_card_id_fkey
    foreign key (card_id)
    references public.digital_cards(id)
    on delete cascade,
  constraint card_buttons_pkey primary key (id)
);

create table public.card_services (
  id uuid default gen_random_uuid() not null,
  card_id uuid not null,
  title text not null,
  description text,
  "position" integer default 0 not null,
  created_at timestamp with time zone default now() not null,
  updated_at timestamp with time zone default now() not null,
  constraint card_services_card_id_fkey
    foreign key (card_id)
    references public.digital_cards(id)
    on delete cascade,
  constraint card_services_card_id_position_key
    unique (card_id, "position"),
  constraint card_services_pkey primary key (id),
  constraint card_services_position_check check ("position" >= 0)
);

create table public.card_socials (
  id uuid default gen_random_uuid() not null,
  card_id uuid not null,
  platform text not null,
  url text not null,
  created_at timestamp with time zone default now(),
  constraint card_socials_card_id_fkey
    foreign key (card_id)
    references public.digital_cards(id)
    on delete cascade,
  constraint card_socials_pkey primary key (id),
  constraint card_socials_platform_check check (
    platform = any (
      array[
        'facebook'::text,
        'instagram'::text,
        'linkedin'::text,
        'tiktok'::text,
        'youtube'::text,
        'x'::text
      ]
    )
  ),
  constraint card_socials_url_check check (
    char_length(url) >= 8
    and char_length(url) <= 2048
    and url ~* '^https?://'::text
  )
);

CREATE OR REPLACE FUNCTION public.card_services_set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;

create index card_buttons_card_id_position_idx
on public.card_buttons using btree (card_id, "position");

create unique index card_socials_card_id_platform_key
on public.card_socials using btree (card_id, platform);

CREATE TRIGGER card_services_set_updated_at
BEFORE UPDATE ON card_services
FOR EACH ROW
EXECUTE FUNCTION card_services_set_updated_at();

alter table public.card_buttons enable row level security;
alter table public.card_services enable row level security;
alter table public.card_socials enable row level security;

create policy "Authenticated reads permitted card buttons"
on public.card_buttons
as permissive
for select
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_buttons.card_id) AND (private.is_organization_member(c.organization_id) OR ((c.organization_id IS NULL) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))));

create policy "Authorized members insert card buttons"
on public.card_buttons
as permissive
for insert
to authenticated
with check ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_buttons.card_id) AND (private.has_organization_role(c.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]) OR ((c.organization_id IS NULL) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))));

create policy "Authorized members update card buttons"
on public.card_buttons
as permissive
for update
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_buttons.card_id) AND (private.has_organization_role(c.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]) OR ((c.organization_id IS NULL) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))))
with check ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_buttons.card_id) AND (private.has_organization_role(c.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]) OR ((c.organization_id IS NULL) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))));

create policy "Authorized members delete card buttons"
on public.card_buttons
as permissive
for delete
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_buttons.card_id) AND (private.has_organization_role(c.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]) OR ((c.organization_id IS NULL) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))));

create policy "Public reads buttons of published cards"
on public.card_buttons
as permissive
for select
to anon, authenticated
using (((enabled = true) AND (EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_buttons.card_id) AND (c.status = 'published'::text))))));

create policy "Authenticated reads permitted card services"
on public.card_services
as permissive
for select
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_services.card_id) AND (private.is_organization_member(c.organization_id) OR ((c.organization_id IS NULL) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))));

create policy "Authorized members insert card services"
on public.card_services
as permissive
for insert
to authenticated
with check ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_services.card_id) AND (private.has_organization_role(c.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]) OR ((c.organization_id IS NULL) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))));

create policy "Authorized members update card services"
on public.card_services
as permissive
for update
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_services.card_id) AND (private.has_organization_role(c.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]) OR ((c.organization_id IS NULL) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))))
with check ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_services.card_id) AND (private.has_organization_role(c.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]) OR ((c.organization_id IS NULL) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))));

create policy "Authorized members delete card services"
on public.card_services
as permissive
for delete
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_services.card_id) AND (private.has_organization_role(c.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]) OR ((c.organization_id IS NULL) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))));

create policy "Public reads services of published cards"
on public.card_services
as permissive
for select
to anon, authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_services.card_id) AND (c.status = 'published'::text)))));

create policy "Anonymous reads socials for published cards"
on public.card_socials
as permissive
for select
to anon
using ((EXISTS ( SELECT 1
   FROM digital_cards d
  WHERE ((d.id = card_socials.card_id) AND (d.status = 'published'::text)))));

create policy "Authenticated reads permitted card socials"
on public.card_socials
as permissive
for select
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards d
  WHERE ((d.id = card_socials.card_id) AND ((d.status = 'published'::text) OR (d.owner_id = ( SELECT auth.uid() AS uid)) OR private.is_organization_member(d.organization_id))))));

create policy "Authorized members delete card socials"
on public.card_socials
as permissive
for delete
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards d
  WHERE ((d.id = card_socials.card_id) AND ((d.owner_id = ( SELECT auth.uid() AS uid)) OR private.has_organization_role(d.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]))))));

create policy "Authorized members insert card socials"
on public.card_socials
as permissive
for insert
to authenticated
with check ((EXISTS ( SELECT 1
   FROM digital_cards d
  WHERE ((d.id = card_socials.card_id) AND ((d.owner_id = ( SELECT auth.uid() AS uid)) OR private.has_organization_role(d.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]))))));

create policy "Authorized members update card socials"
on public.card_socials
as permissive
for update
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards d
  WHERE ((d.id = card_socials.card_id) AND ((d.owner_id = ( SELECT auth.uid() AS uid)) OR private.has_organization_role(d.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]))))))
with check ((EXISTS ( SELECT 1
   FROM digital_cards d
  WHERE ((d.id = card_socials.card_id) AND ((d.owner_id = ( SELECT auth.uid() AS uid)) OR private.has_organization_role(d.organization_id, ARRAY['owner'::text, 'admin'::text, 'editor'::text]))))));


-- Invitaciones
do $preconditions$
begin
  if to_regnamespace('private') is null then
    raise exception 'Falta el esquema private requerido por invitaciones.';
  end if;
  if to_regclass('public.organizations') is null
     or to_regclass('public.organization_members') is null
     or to_regclass('public.organization_subscriptions') is null
     or to_regclass('public.plans') is null then
    raise exception 'Falta el núcleo organizacional requerido por invitaciones.';
  end if;
  if to_regprocedure('private.get_effective_plan(uuid)') is null
     or to_regprocedure('private.lock_member_plan_context(uuid,boolean)') is null
     or to_regprocedure('private.set_updated_at()') is null then
    raise exception 'Faltan helpers previos de plan, miembros o timestamps.';
  end if;
  if to_regprocedure('extensions.digest(bytea,text)') is null then
    raise exception 'Falta extensions.digest(bytea,text) (pgcrypto).';
  end if;
end;
$preconditions$;

create table public.organization_invitations (
  id uuid not null default gen_random_uuid(),
  organization_id uuid not null,
  email text not null,
  role text not null,
  status text not null default 'pending'::text,
  invited_by uuid,
  accepted_by uuid,
  token_hash bytea not null,
  expires_at timestamp with time zone not null,
  accepted_at timestamp with time zone,
  revoked_at timestamp with time zone,
  last_sent_at timestamp with time zone not null default now(),
  send_count integer not null default 1,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint organization_invitations_pkey primary key (id),
  constraint organization_invitations_organization_id_fkey
    foreign key (organization_id)
    references public.organizations(id)
    on delete cascade,
  constraint organization_invitations_invited_by_fkey
    foreign key (invited_by)
    references auth.users(id)
    on delete set null,
  constraint organization_invitations_accepted_by_fkey
    foreign key (accepted_by)
    references auth.users(id)
    on delete set null,
  constraint organization_invitations_email_normalized_check
    check (
      email = lower(btrim(email))
      and char_length(email) >= 3
      and char_length(email) <= 320
      and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'::text
    ),
  constraint organization_invitations_role_check
    check (role = any (array['owner'::text, 'admin'::text, 'editor'::text, 'viewer'::text])),
  constraint organization_invitations_status_check
    check (status = any (array['pending'::text, 'accepted'::text, 'expired'::text, 'revoked'::text])),
  constraint organization_invitations_token_hash_check
    check (octet_length(token_hash) = 32),
  constraint organization_invitations_expiry_check
    check (expires_at > created_at),
  constraint organization_invitations_send_count_check
    check (send_count >= 1 and send_count <= 20),
  constraint organization_invitations_timestamps_check
    check (updated_at >= created_at),
  constraint organization_invitations_state_check
    check (
      (
        status = 'accepted'::text
        and accepted_at is not null
        and revoked_at is null
      )
      or (
        status = 'revoked'::text
        and revoked_at is not null
        and accepted_at is null
        and accepted_by is null
      )
      or (
        status = any (array['pending'::text, 'expired'::text])
        and accepted_at is null
        and accepted_by is null
        and revoked_at is null
      )
    )
);

create index organization_invitations_expiration_idx
  on public.organization_invitations using btree (expires_at)
  where status = 'pending'::text;

create unique index organization_invitations_one_pending_email_idx
  on public.organization_invitations using btree (organization_id, email)
  where status = 'pending'::text;

create index organization_invitations_org_status_created_idx
  on public.organization_invitations using btree (organization_id, status, created_at desc);

create unique index organization_invitations_token_hash_idx
  on public.organization_invitations using btree (token_hash);

create trigger organization_invitations_set_updated_at
before update on public.organization_invitations
for each row
execute function private.set_updated_at();

CREATE OR REPLACE FUNCTION private.invitation_actor_role(target_organization_id uuid, actor_user_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
  select member.role
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = actor_user_id
    and member.status = 'active'
    and member.role in ('owner', 'admin')
  limit 1;
$function$;

CREATE OR REPLACE FUNCTION public.create_organization_invitation(target_organization_id uuid, invitation_email text, invitation_role text, invitation_token_hash bytea, invitation_expires_at timestamp with time zone, actor_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  normalized_email text :=
    lower(btrim(coalesce(invitation_email, '')));

  normalized_role text :=
    lower(btrim(coalesce(invitation_role, '')));

  initial_actor_role text;
  locked_actor_role text;

  existing_invitation
    public.organization_invitations%rowtype;

  inserted_invitation
    public.organization_invitations%rowtype;
begin
  if target_organization_id is null
     or actor_user_id is null
     or normalized_email = ''
     or normalized_role not in (
       'owner', 'admin', 'editor', 'viewer'
     )
     or invitation_token_hash is null
     or octet_length(invitation_token_hash) <> 32
     or invitation_expires_at <= now()
     or invitation_expires_at >
       now() + interval '14 days'
  then
    raise exception using
      errcode = '22023',
      message = 'La solicitud de invitación no es válida.';
  end if;

  initial_actor_role :=
    private.invitation_actor_role(
      target_organization_id,
      actor_user_id
    );

  if initial_actor_role is null
     or (
       initial_actor_role = 'admin'
       and normalized_role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message =
        'No tienes permiso para crear esta invitación.';
  end if;

  perform *
  from private.lock_member_plan_context(
    target_organization_id,
    true
  );

  select invitation.*
  into existing_invitation
  from public.organization_invitations as invitation
  where invitation.organization_id =
      target_organization_id
    and invitation.email = normalized_email
    and invitation.status = 'pending'
  order by invitation.created_at desc
  limit 1
  for update;

  select member.role
  into locked_actor_role
  from public.organization_members as member
  where member.organization_id =
      target_organization_id
    and member.user_id = actor_user_id
    and member.status = 'active'
  for share;

  if locked_actor_role is null
     or locked_actor_role is distinct from
       initial_actor_role
     or (
       locked_actor_role = 'admin'
       and normalized_role = 'owner'
     )
  then
    raise exception using
      errcode = '40001',
      message =
        'Tus permisos cambiaron durante la operación. Intenta nuevamente.';
  end if;

  if existing_invitation.id is not null then
    if existing_invitation.expires_at <= now() then
      update public.organization_invitations as invitation
      set
        status = 'expired',
        updated_at = now()
      where invitation.id = existing_invitation.id;
    else
      raise exception using
        errcode = '23505',
        message =
          'Ya existe una invitación pendiente para ese correo.';
    end if;
  end if;

  if (
    select count(*)
    from public.organization_invitations as invitation
    where invitation.organization_id =
      target_organization_id
      and invitation.created_at >=
        now() - interval '24 hours'
  ) >= 20 then
    raise exception using
      errcode = 'P0001',
      message =
        'Se alcanzó temporalmente el límite de invitaciones.';
  end if;

  if exists (
    select 1
    from public.organization_members as member
    join auth.users as auth_user
      on auth_user.id = member.user_id
    where member.organization_id =
      target_organization_id
      and lower(btrim(auth_user.email)) =
        normalized_email
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'No se pudo crear la invitación.';
  end if;

  insert into public.organization_invitations (
    organization_id,
    email,
    role,
    status,
    invited_by,
    token_hash,
    expires_at,
    last_sent_at,
    send_count
  )
  values (
    target_organization_id,
    normalized_email,
    normalized_role,
    'pending',
    actor_user_id,
    invitation_token_hash,
    invitation_expires_at,
    now(),
    1
  )
  returning *
  into inserted_invitation;

  return jsonb_build_object(
    'id', inserted_invitation.id,
    'email', inserted_invitation.email,
    'role', inserted_invitation.role,
    'expires_at', inserted_invitation.expires_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_organization_invitations(target_organization_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid := auth.uid();
  caller_role text;
  invitations jsonb;
begin
  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  caller_role :=
    private.invitation_actor_role(
      target_organization_id,
      current_user_id
    );

  if caller_role is null then
    raise exception using
      errcode = '42501',
      message =
        'No tienes permiso para consultar invitaciones.';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', invitation.id,
        'email', invitation.email,
        'role', invitation.role,
        'status',
          case
            when invitation.status = 'pending'
             and invitation.expires_at <= now()
              then 'expired'
            else invitation.status
          end,
        'expires_at', invitation.expires_at,
        'accepted_at', invitation.accepted_at,
        'created_at', invitation.created_at,
        'updated_at', invitation.updated_at,
        'last_sent_at', invitation.last_sent_at,
        'send_count', invitation.send_count
      )
      order by invitation.created_at desc
    ),
    '[]'::jsonb
  )
  into invitations
  from public.organization_invitations as invitation
  where invitation.organization_id =
    target_organization_id;

  return jsonb_build_object(
    'items', invitations,
    'caller_role', caller_role
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.resend_organization_invitation(target_invitation_id uuid, invitation_token_hash bytea, invitation_expires_at timestamp with time zone, actor_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  initial_invitation record;
  initial_actor_role text;
  locked_actor_role text;

  locked_invitation
    public.organization_invitations%rowtype;
begin
  if target_invitation_id is null
     or actor_user_id is null
     or invitation_token_hash is null
     or octet_length(invitation_token_hash) <> 32
     or invitation_expires_at <= now()
     or invitation_expires_at >
       now() + interval '14 days'
  then
    raise exception using
      errcode = '22023',
      message = 'La solicitud de reenvío no es válida.';
  end if;

  select
    invitation.organization_id,
    invitation.role
  into initial_invitation
  from public.organization_invitations as invitation
  where invitation.id = target_invitation_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'No se pudo procesar la invitación.';
  end if;

  initial_actor_role :=
    private.invitation_actor_role(
      initial_invitation.organization_id,
      actor_user_id
    );

  if initial_actor_role is null
     or (
       initial_actor_role = 'admin'
       and initial_invitation.role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message =
        'No tienes permiso para reenviar esta invitación.';
  end if;

  perform *
  from private.lock_member_plan_context(
    initial_invitation.organization_id,
    true
  );

  select invitation.*
  into locked_invitation
  from public.organization_invitations as invitation
  where invitation.id = target_invitation_id
    and invitation.organization_id =
      initial_invitation.organization_id
  for update;

  if not found
     or locked_invitation.role is distinct from
       initial_invitation.role
  then
    raise exception using
      errcode = '40001',
      message =
        'La invitación cambió durante la operación. Intenta nuevamente.';
  end if;

  select member.role
  into locked_actor_role
  from public.organization_members as member
  where member.organization_id =
      initial_invitation.organization_id
    and member.user_id = actor_user_id
    and member.status = 'active'
  for share;

  if locked_actor_role is null
     or locked_actor_role is distinct from
       initial_actor_role
     or (
       locked_actor_role = 'admin'
       and locked_invitation.role = 'owner'
     )
  then
    raise exception using
      errcode = '40001',
      message =
        'Tus permisos cambiaron durante la operación. Intenta nuevamente.';
  end if;

  if locked_invitation.status not in (
       'pending', 'expired'
     )
     or locked_invitation.last_sent_at >
       now() - interval '60 seconds'
     or locked_invitation.send_count >= 5
  then
    raise exception using
      errcode = 'P0001',
      message = 'No se pudo reenviar la invitación.';
  end if;

  update public.organization_invitations as invitation
  set
    status = 'pending',
    token_hash = invitation_token_hash,
    expires_at = invitation_expires_at,
    accepted_by = null,
    accepted_at = null,
    revoked_at = null,
    last_sent_at = now(),
    send_count = invitation.send_count + 1,
    updated_at = now()
  where invitation.id = target_invitation_id
  returning *
  into locked_invitation;

  return jsonb_build_object(
    'id', locked_invitation.id,
    'organization_id', locked_invitation.organization_id,
    'email', locked_invitation.email,
    'role', locked_invitation.role,
    'expires_at', locked_invitation.expires_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.revoke_organization_invitation(target_invitation_id uuid, actor_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  initial_invitation record;
  initial_actor_role text;
  locked_actor_role text;

  locked_invitation
    public.organization_invitations%rowtype;
begin
  select
    invitation.organization_id,
    invitation.role
  into initial_invitation
  from public.organization_invitations as invitation
  where invitation.id = target_invitation_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'No se pudo procesar la invitación.';
  end if;

  initial_actor_role :=
    private.invitation_actor_role(
      initial_invitation.organization_id,
      actor_user_id
    );

  if initial_actor_role is null
     or (
       initial_actor_role = 'admin'
       and initial_invitation.role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message =
        'No tienes permiso para revocar esta invitación.';
  end if;

  perform 1
  from public.organizations as organization
  where organization.id =
    initial_invitation.organization_id
  for update;

  select invitation.*
  into locked_invitation
  from public.organization_invitations as invitation
  where invitation.id = target_invitation_id
    and invitation.organization_id =
      initial_invitation.organization_id
  for update;

  select member.role
  into locked_actor_role
  from public.organization_members as member
  where member.organization_id =
      initial_invitation.organization_id
    and member.user_id = actor_user_id
    and member.status = 'active'
  for share;

  if locked_actor_role is null
     or locked_actor_role is distinct from
       initial_actor_role
     or locked_invitation.status <> 'pending'
     or (
       locked_actor_role = 'admin'
       and locked_invitation.role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message = 'No se pudo revocar la invitación.';
  end if;

  update public.organization_invitations as invitation
  set
    status = 'revoked',
    revoked_at = now(),
    updated_at = now()
  where invitation.id = target_invitation_id;

  return jsonb_build_object(
    'id', target_invitation_id,
    'revoked', true
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.accept_organization_invitation(invitation_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid := auth.uid();
  current_email text;
  calculated_hash bytea;

  initial_invitation record;

  locked_invitation
    public.organization_invitations%rowtype;

  locked_inviter_role text;
begin
  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  /*
   * Contrato obligatorio para Paso B:
   *
   * 1. Generar exactamente 32 bytes aleatorios.
   * 2. Codificarlos como base64url sin padding.
   * 3. El resultado debe tener exactamente 43 caracteres.
   * 4. Calcular SHA-256 sobre la cadena base64url de
   *    43 caracteres codificada como UTF-8.
   * 5. Guardar solamente los 32 bytes resultantes del hash.
   *
   * No calcular el hash directamente sobre los 32 bytes
   * aleatorios originales.
   */
  if coalesce(invitation_token, '') !~
       '^[A-Za-z0-9_-]{43}$'
  then
    raise exception using
      errcode = 'P0001',
      message =
        'La invitación no es válida o ha expirado.';
  end if;

  calculated_hash :=
    extensions.digest(
      convert_to(invitation_token, 'UTF8'),
      'sha256'
    );

  select
    invitation.id,
    invitation.organization_id
  into initial_invitation
  from public.organization_invitations as invitation
  where invitation.token_hash = calculated_hash
    and invitation.status = 'pending'
    and invitation.expires_at > now();

  if not found then
    raise exception using
      errcode = 'P0001',
      message =
        'La invitación no es válida o ha expirado.';
  end if;

  perform *
  from private.lock_member_plan_context(
    initial_invitation.organization_id,
    true
  );

  select invitation.*
  into locked_invitation
  from public.organization_invitations as invitation
  where invitation.id = initial_invitation.id
    and invitation.organization_id =
      initial_invitation.organization_id
    and invitation.token_hash = calculated_hash
    and invitation.status = 'pending'
    and invitation.expires_at > now()
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message =
        'La invitación no es válida o ha expirado.';
  end if;

  select member.role
  into locked_inviter_role
  from public.organization_members as member
  where member.organization_id =
      locked_invitation.organization_id
    and member.user_id =
      locked_invitation.invited_by
    and member.status = 'active'
    and member.role in ('owner', 'admin')
  for share;

  if locked_inviter_role is null
     or (
       locked_inviter_role = 'admin'
       and locked_invitation.role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message =
        'La invitación ya no puede aceptarse.';
  end if;

  select lower(btrim(auth_user.email))
  into current_email
  from auth.users as auth_user
  where auth_user.id = current_user_id
    and auth_user.email is not null
    and auth_user.deleted_at is null
    and auth_user.is_anonymous = false
    and coalesce(
      auth_user.email_confirmed_at,
      auth_user.confirmed_at
    ) is not null
    and (
      auth_user.banned_until is null
      or auth_user.banned_until <= now()
    );

  if current_email is null
     or current_email <> locked_invitation.email
  then
    raise exception using
      errcode = '42501',
      message =
        'La invitación no es válida para esta cuenta.';
  end if;

  if exists (
    select 1
    from public.organization_members as member
    where member.organization_id =
      locked_invitation.organization_id
      and member.user_id = current_user_id
  ) then
    raise exception using
      errcode = '23505',
      message =
        'La cuenta ya pertenece a la organización.';
  end if;

  insert into public.organization_members (
    organization_id,
    user_id,
    role,
    status,
    created_by
  )
  values (
    locked_invitation.organization_id,
    current_user_id,
    locked_invitation.role,
    'active',
    locked_invitation.invited_by
  );

  update public.organization_invitations as invitation
  set
    status = 'accepted',
    accepted_by = current_user_id,
    accepted_at = now(),
    updated_at = now()
  where invitation.id = locked_invitation.id;

  return jsonb_build_object(
    'organization_id',
      locked_invitation.organization_id,
    'role',
      locked_invitation.role,
    'status',
      'accepted'
  );
end;
$function$;

alter table public.organization_invitations enable row level security;

-- ACL finales consolidadas. Los ACL internos de storage.objects continúan
-- administrados por supabase_storage_admin y no se alteran aquí.
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

revoke all privileges
on table public.prospects, public.card_events
from public, anon, authenticated, service_role;

grant insert, references, trigger, truncate, maintain
on table public.prospects, public.card_events
to service_role;

revoke all privileges
on table public.card_buttons,
         public.card_services,
         public.card_socials
from public, anon, authenticated, service_role;

grant truncate, references, trigger, maintain
on table public.card_buttons,
         public.card_services
to anon, authenticated, service_role;

grant select
on table public.card_buttons,
         public.card_services
to anon, authenticated;

grant insert, update, delete
on table public.card_buttons,
         public.card_services
to authenticated;

grant select, truncate, references, trigger, maintain
on table public.card_socials
to anon;

grant select, insert, update, delete,
      truncate, references, trigger, maintain
on table public.card_socials
to authenticated;

grant truncate, references, trigger, maintain
on table public.card_socials
to service_role;

revoke all privileges
on table public.organization_invitations
from public, anon, authenticated;

revoke select, insert, update, delete
on table public.organization_invitations
from service_role;

revoke all on function private.set_updated_at() from public, anon, authenticated, service_role;
revoke all on function private.qr_relative_luminance(text) from public, anon, authenticated, service_role;
revoke all on function private.qr_contrast_ratio(text, text) from public, anon, authenticated, service_role;
revoke all on function private.is_organization_member(uuid) from public, anon, authenticated, service_role;
revoke all on function private.has_organization_role(uuid, text[]) from public, anon, authenticated, service_role;
revoke all on function private.get_effective_plan(uuid) from public, anon, authenticated, service_role;
revoke all on function private.ensure_organization_has_active_owner() from public, anon, authenticated, service_role;
revoke all on function private.validate_card_media_reference_change() from public, anon, authenticated, service_role;
revoke all on function private.validate_card_qr_settings_change() from public, anon, authenticated, service_role;
revoke all on function private.lock_member_plan_context(uuid, boolean) from public, anon, authenticated, service_role;
revoke all on function private.card_media_delete_allowed(text) from public, anon, authenticated, service_role;
revoke all on function private.card_media_identity_unchanged(uuid, uuid, uuid, text, text, timestamp with time zone, text) from public, anon, authenticated, service_role;
revoke all on function private.card_media_read_allowed(text) from public, anon, authenticated, service_role;
revoke all on function private.card_media_reference_allowed(uuid, text, text, text) from public, anon, authenticated, service_role;
revoke all on function private.card_media_upload_allowed(text, jsonb) from public, anon, authenticated, service_role;
revoke all on function private.get_effective_qr_plan(uuid) from public, anon, authenticated, service_role;
revoke all on function private.lock_card_media_plan(uuid, text) from public, anon, authenticated, service_role;
revoke all on function private.lock_effective_qr_plan(uuid) from public, anon, authenticated, service_role;
revoke all on function private.qr_capability_enabled(jsonb, text) from public, anon, authenticated, service_role;
revoke all on function private.lock_lead_capture_plan(uuid) from public, anon, authenticated, service_role;
revoke all on function private.invitation_actor_role(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function private.organization_role(uuid) from public, anon, authenticated, service_role;

revoke all on function public.digital_cards_set_timestamps() from public, anon, authenticated, service_role;
revoke all on function public.card_services_set_updated_at() from public, anon, authenticated, service_role;
revoke all on function public.record_lead_created_event() from public, anon, authenticated, service_role;
revoke all on function public.create_organization_card(uuid, text, text, text, text, text, text, text, text, text, text, text, boolean) from public, anon, authenticated, service_role;
revoke all on function public.update_organization_card(uuid, text, text, text, text, text, text, text, text, text, text, boolean) from public, anon, authenticated, service_role;
revoke all on function public.set_card_status(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.list_organization_members(uuid) from public, anon, authenticated, service_role;
revoke all on function public.add_organization_member_by_email(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.update_organization_member(uuid, uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.remove_organization_member(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.get_organization_qr_capabilities(uuid) from public, anon, authenticated, service_role;
revoke all on function public.set_card_media_reference(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.set_card_qr_settings(uuid, text, text, boolean, numeric, text) from public, anon, authenticated, service_role;
revoke all on function public.create_public_prospect(uuid, text, text, text, text, boolean) from public, anon, authenticated, service_role;
revoke all on function public.get_organization_metrics(uuid, uuid, integer) from public, anon, authenticated, service_role;
revoke all on function public.list_organization_prospects(uuid, uuid, integer, integer, text) from public, anon, authenticated, service_role;
revoke all on function public.create_organization_invitation(uuid, text, text, bytea, timestamp with time zone, uuid) from public, anon, authenticated, service_role;
revoke all on function public.list_organization_invitations(uuid) from public, anon, authenticated, service_role;
revoke all on function public.resend_organization_invitation(uuid, bytea, timestamp with time zone, uuid) from public, anon, authenticated, service_role;
revoke all on function public.revoke_organization_invitation(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.accept_organization_invitation(text) from public, anon, authenticated, service_role;

grant execute on function private.is_organization_member(uuid) to authenticated;
grant execute on function private.has_organization_role(uuid, text[]) to authenticated;
grant execute on function private.organization_role(uuid) to authenticated;
grant execute on function private.card_media_delete_allowed(text) to authenticated;
grant execute on function private.card_media_read_allowed(text) to authenticated;
grant execute on function private.card_media_upload_allowed(text, jsonb) to authenticated;

grant execute on function public.create_organization_card(uuid, text, text, text, text, text, text, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.update_organization_card(uuid, text, text, text, text, text, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.set_card_status(uuid, text) to authenticated;
grant execute on function public.list_organization_members(uuid) to authenticated;
grant execute on function public.add_organization_member_by_email(uuid, text, text) to authenticated;
grant execute on function public.update_organization_member(uuid, uuid, text, text) to authenticated;
grant execute on function public.remove_organization_member(uuid, uuid) to authenticated;
grant execute on function public.get_organization_qr_capabilities(uuid) to authenticated;
grant execute on function public.set_card_media_reference(uuid, text, text) to authenticated;
grant execute on function public.set_card_qr_settings(uuid, text, text, boolean, numeric, text) to authenticated;
grant execute on function public.get_organization_metrics(uuid, uuid, integer) to authenticated;
grant execute on function public.list_organization_prospects(uuid, uuid, integer, integer, text) to authenticated;
grant execute on function public.list_organization_invitations(uuid) to authenticated;
grant execute on function public.accept_organization_invitation(text) to authenticated;

grant execute on function public.create_public_prospect(uuid, text, text, text, text, boolean) to service_role;
grant execute on function public.create_organization_invitation(uuid, text, text, bytea, timestamp with time zone, uuid) to service_role;
grant execute on function public.resend_organization_invitation(uuid, bytea, timestamp with time zone, uuid) to service_role;
grant execute on function public.revoke_organization_invitation(uuid, uuid) to service_role;

-- Postflight estructural y de seguridad.
DO $baseline_postflight$
DECLARE
  missing_object text;
BEGIN
  SELECT candidate.object_name
  INTO missing_object
  FROM unnest(ARRAY[
    'public.plans','public.organizations','public.organization_members',
    'public.organization_subscriptions','public.digital_cards',
    'public.card_events','public.prospects','public.card_buttons',
    'public.card_services','public.card_socials','public.organization_invitations'
  ]::text[]) AS candidate(object_name)
  WHERE to_regclass(candidate.object_name) IS NULL
  LIMIT 1;

  IF missing_object IS NOT NULL THEN
    RAISE EXCEPTION 'Postflight: falta la tabla %.', missing_object;
  END IF;

  SELECT candidate.object_name
  INTO missing_object
  FROM unnest(ARRAY[
    'private.get_effective_plan(uuid)',
    'private.lock_member_plan_context(uuid,boolean)',
    'private.card_media_upload_allowed(text,jsonb)',
    'private.lock_lead_capture_plan(uuid)',
    'private.invitation_actor_role(uuid,uuid)',
    'private.organization_role(uuid)',
    'public.create_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,text,boolean)',
    'public.update_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,boolean)',
    'public.set_card_status(uuid,text)',
    'public.list_organization_members(uuid)',
    'public.set_card_media_reference(uuid,text,text)',
    'public.get_organization_qr_capabilities(uuid)',
    'public.set_card_qr_settings(uuid,text,text,boolean,numeric,text)',
    'public.create_public_prospect(uuid,text,text,text,text,boolean)',
    'public.get_organization_metrics(uuid,uuid,integer)',
    'public.list_organization_prospects(uuid,uuid,integer,integer,text)',
    'public.create_organization_invitation(uuid,text,text,bytea,timestamp with time zone,uuid)',
    'public.list_organization_invitations(uuid)',
    'public.resend_organization_invitation(uuid,bytea,timestamp with time zone,uuid)',
    'public.revoke_organization_invitation(uuid,uuid)',
    'public.accept_organization_invitation(text)'
  ]::text[]) AS candidate(object_name)
  WHERE to_regprocedure(candidate.object_name) IS NULL
  LIMIT 1;

  IF missing_object IS NOT NULL THEN
    RAISE EXCEPTION 'Postflight: falta la función %.', missing_object;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM storage.buckets AS bucket
    WHERE bucket.id = 'digital-card-media'
      AND bucket.name = 'digital-card-media'
      AND bucket.public = false
      AND bucket.file_size_limit = 2097152
      AND bucket.allowed_mime_types = ARRAY['image/jpeg','image/png','image/webp']::text[]
  ) THEN
    RAISE EXCEPTION 'Postflight: la configuración de digital-card-media no coincide.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM pg_policies AS policy
    WHERE policy.schemaname = 'storage'
      AND policy.tablename = 'objects'
      AND policy.cmd = 'UPDATE'
      AND ('anon' = ANY(policy.roles) OR 'authenticated' = ANY(policy.roles))
  ) THEN
    RAISE EXCEPTION 'Postflight: existe una policy Storage UPDATE para navegador.';
  END IF;

  IF (
    SELECT count(*)
    FROM pg_policies
    WHERE schemaname = 'storage'
      AND tablename = 'objects'
      AND policyname IN (
        'Organization members read card media',
        'Organization roles delete unreferenced card media',
        'Organization roles upload card media',
        'Published card media is publicly readable'
      )
  ) <> 4 THEN
    RAISE EXCEPTION 'Postflight: faltan policies de Storage.';
  END IF;

  IF has_table_privilege('anon', 'public.prospects', 'SELECT')
     OR has_table_privilege('authenticated', 'public.prospects', 'SELECT')
     OR has_table_privilege('anon', 'public.card_events', 'SELECT')
     OR has_table_privilege('authenticated', 'public.card_events', 'SELECT')
     OR has_table_privilege('anon', 'public.organization_invitations', 'SELECT')
     OR has_table_privilege('authenticated', 'public.organization_invitations', 'SELECT')
  THEN
    RAISE EXCEPTION 'Postflight: existe acceso directo indebido a datos protegidos.';
  END IF;

  IF NOT has_table_privilege('anon', 'public.digital_cards', 'SELECT')
     OR NOT has_table_privilege('authenticated', 'public.digital_cards', 'SELECT')
     OR has_table_privilege('authenticated', 'public.digital_cards', 'INSERT')
     OR has_table_privilege('authenticated', 'public.digital_cards', 'UPDATE')
     OR has_table_privilege('authenticated', 'public.digital_cards', 'DELETE')
  THEN
    RAISE EXCEPTION 'Postflight: ACL de digital_cards no coincide.';
  END IF;

  IF NOT has_function_privilege('authenticated', 'public.create_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,text,boolean)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.create_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,text,boolean)', 'EXECUTE')
     OR NOT has_function_privilege('service_role', 'public.create_public_prospect(uuid,text,text,text,text,boolean)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.create_public_prospect(uuid,text,text,text,text,boolean)', 'EXECUTE')
  THEN
    RAISE EXCEPTION 'Postflight: ACL de RPC principales no coincide.';
  END IF;
END;
$baseline_postflight$;

commit;
