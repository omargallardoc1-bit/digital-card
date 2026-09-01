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
  if auth.uid() is null or target_card_id is null or media_type not in ('profile','logo','cover') then
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
  into initial_organization_id, initial_owner_id, initial_reference
  from public.digital_cards card
  where card.id = target_card_id;

  if initial_organization_id is null
     or initial_owner_id is null
     or initial_reference is distinct from expected_previous_reference then
    return false;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(target_card_id::text || '/' || media_type, 0));

  if object_name is not null then
    select *
    into plan_decision
    from private.lock_card_media_plan(initial_organization_id, media_type);

    if plan_decision.subscription_status is null or plan_decision.capability_enabled is not true then
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
    and member.role in ('owner','admin','editor')
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
  into locked_organization_id, locked_owner_id, locked_reference
  from public.digital_cards card
  where card.id = target_card_id
  for update;

  if locked_organization_id is distinct from initial_organization_id
     or locked_owner_id is distinct from initial_owner_id
     or locked_reference is distinct from initial_reference
     or locked_reference is distinct from expected_previous_reference then
    return false;
  end if;

  if object_name is null then
    return true;
  end if;

  if plan_decision.subscription_status = 'past_due' and locked_reference is null then
    return false;
  end if;

  expected_prefix := locked_owner_id::text || '/' || target_card_id::text || '/' || media_type || '/';

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
      and storage.filename(object.name) ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
      and object.metadata->>'mimetype' in ('image/jpeg','image/png','image/webp')
      and coalesce(object.metadata->>'size','') ~ '^[0-9]+$'
      and (object.metadata->>'size')::bigint between 1 and 2097152
  );
end;
$function$;

revoke all on function private.card_media_reference_allowed(uuid,text,text,text) from public, anon, authenticated, service_role;
grant execute on function private.card_media_reference_allowed(uuid,text,text,text) to authenticated;
