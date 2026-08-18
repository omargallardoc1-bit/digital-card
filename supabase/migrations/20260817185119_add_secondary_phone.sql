begin;

do $preflight$
begin
  if to_regclass('public.digital_cards') is null then
    raise exception 'Precondition failed: public.digital_cards does not exist';
  end if;

  if exists (
    select 1
    from pg_catalog.pg_attribute
    where attrelid = 'public.digital_cards'::regclass
      and attname = 'secondary_phone'
      and not attisdropped
  ) then
    raise exception 'Precondition failed: public.digital_cards.secondary_phone already exists';
  end if;

  if to_regprocedure('public.create_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,text,boolean)') is null
     or to_regprocedure('public.update_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,boolean)') is null
  then
    raise exception 'Precondition failed: current organization card RPC signatures are missing';
  end if;

  if to_regprocedure('public.create_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,text,boolean,text)') is not null
     or to_regprocedure('public.update_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,boolean,text)') is not null
  then
    raise exception 'Precondition failed: secondary phone RPC signatures already exist';
  end if;
end;
$preflight$;

alter table public.digital_cards
  add column secondary_phone text,
  add constraint digital_cards_secondary_phone_length_check
    check (
      secondary_phone is null
      or char_length(secondary_phone) <= 40
    );

drop function public.create_organization_card(
  uuid, text, text, text, text, text, text,
  text, text, text, text, text, boolean
);

drop function public.update_organization_card(
  uuid, text, text, text, text, text,
  text, text, text, text, text, boolean
);

CREATE OR REPLACE FUNCTION public.create_organization_card(target_organization_id uuid, card_slug text, card_name text, card_position text DEFAULT NULL::text, card_company text DEFAULT NULL::text, card_slogan text DEFAULT NULL::text, card_description text DEFAULT NULL::text, card_phone text DEFAULT NULL::text, card_whatsapp text DEFAULT NULL::text, card_email text DEFAULT NULL::text, card_website text DEFAULT NULL::text, card_location text DEFAULT NULL::text, card_capture_enabled boolean DEFAULT false, card_secondary_phone text DEFAULT NULL::text)
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
     or char_length(coalesce(card_secondary_phone, '')) > 40
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
    secondary_phone,
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
    nullif(btrim(coalesce(card_secondary_phone, '')), ''),
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

CREATE OR REPLACE FUNCTION public.update_organization_card(target_card_id uuid, card_name text, card_position text DEFAULT NULL::text, card_company text DEFAULT NULL::text, card_slogan text DEFAULT NULL::text, card_description text DEFAULT NULL::text, card_phone text DEFAULT NULL::text, card_whatsapp text DEFAULT NULL::text, card_email text DEFAULT NULL::text, card_website text DEFAULT NULL::text, card_location text DEFAULT NULL::text, card_capture_enabled boolean DEFAULT false, card_secondary_phone text DEFAULT NULL::text)
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
     or char_length(coalesce(card_secondary_phone, '')) > 40
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
    secondary_phone = nullif(btrim(coalesce(card_secondary_phone, '')), ''),
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

revoke all on function public.create_organization_card(
  uuid, text, text, text, text, text, text,
  text, text, text, text, text, boolean, text
) from public, anon, authenticated, service_role;

revoke all on function public.update_organization_card(
  uuid, text, text, text, text, text,
  text, text, text, text, text, boolean, text
) from public, anon, authenticated, service_role;

grant execute on function public.create_organization_card(
  uuid, text, text, text, text, text, text,
  text, text, text, text, text, boolean, text
) to authenticated;

grant execute on function public.update_organization_card(
  uuid, text, text, text, text, text,
  text, text, text, text, text, boolean, text
) to authenticated;

do $postflight$
begin
  if not exists (
    select 1
    from pg_catalog.pg_attribute
    where attrelid = 'public.digital_cards'::regclass
      and attname = 'secondary_phone'
      and atttypid = 'text'::regtype
      and not attnotnull
      and not attisdropped
  ) then
    raise exception 'Postcondition failed: secondary_phone column is invalid';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint
    where conrelid = 'public.digital_cards'::regclass
      and conname = 'digital_cards_secondary_phone_length_check'
      and contype = 'c'
  ) then
    raise exception 'Postcondition failed: secondary_phone constraint is missing';
  end if;

  if to_regprocedure('public.create_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,text,boolean,text)') is null
     or to_regprocedure('public.update_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,boolean,text)') is null
  then
    raise exception 'Postcondition failed: new organization card RPC signatures are missing';
  end if;

  if to_regprocedure('public.create_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,text,boolean)') is not null
     or to_regprocedure('public.update_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,boolean)') is not null
  then
    raise exception 'Postcondition failed: old organization card RPC signatures remain';
  end if;

  if not has_function_privilege('authenticated', 'public.create_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,text,boolean,text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.update_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,boolean,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.create_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,text,boolean,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.update_organization_card(uuid,text,text,text,text,text,text,text,text,text,text,boolean,text)', 'EXECUTE')
  then
    raise exception 'Postcondition failed: organization card RPC privileges are invalid';
  end if;
end;
$postflight$;

commit;
