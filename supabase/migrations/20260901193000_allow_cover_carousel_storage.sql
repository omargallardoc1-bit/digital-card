-- Allow the new cover carousel to store more than the legacy single cover image.

create or replace function public.add_card_cover_image(target_card_id uuid, object_path text)
returns public.card_cover_images
language plpgsql security definer set search_path='pg_catalog'
as $function$
declare
  allowed integer;
  used integer;
  normalized text;
  created public.card_cover_images%rowtype;
  locked_owner_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception using errcode='42501',message='Autenticación requerida.';
  end if;

  normalized:=btrim(coalesce(object_path,''));

  if normalized='' or char_length(normalized)>1024 then
    raise exception using errcode='22023',message='La referencia de portada no es válida.';
  end if;

  select card.owner_id
  into locked_owner_id
  from public.digital_cards card
  join public.organization_members member on member.organization_id=card.organization_id
  where card.id=target_card_id
    and member.user_id=(select auth.uid())
    and member.status='active'
    and member.role in ('owner','admin','editor')
  for update of card;

  if locked_owner_id is null then
    raise exception using errcode='42501',message='No tienes permiso para modificar esta tarjeta.';
  end if;

  if normalized not like locked_owner_id::text || '/' || target_card_id::text || '/cover/%'
     or storage.filename(normalized) !~*
       '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
  then
    raise exception using errcode='22023',message='La referencia de portada no pertenece a esta tarjeta.';
  end if;

  if not exists (
    select 1
    from storage.objects object
    where object.bucket_id='digital-card-media'
      and object.name=normalized
  ) then
    raise exception using errcode='P0002',message='El archivo de portada no existe en Storage.';
  end if;

  select limits.cover_images_limit into allowed from private.card_content_limits(target_card_id) limits;
  select count(*) into used from public.card_cover_images image where image.card_id=target_card_id and image.archived_at is null;

  if used>=allowed then
    raise exception using errcode='P0001',message=format('El plan permite hasta %s fotografías de portada.',allowed);
  end if;

  insert into public.card_cover_images(card_id,object_path,position)
  values(target_card_id,normalized,used) returning * into created;

  if used=0 then
    perform public.set_card_media_reference(target_card_id,'cover',normalized);
  end if;

  return created;
end;
$function$;

revoke all on function public.add_card_cover_image(uuid,text) from public, anon, service_role;
grant execute on function public.add_card_cover_image(uuid,text) to authenticated;

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
  allowed_cover_images integer;
  active_cover_images integer;
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

  if media_type = 'cover' then
    select limits.cover_images_limit
    into allowed_cover_images
    from private.card_content_limits(target_card_id) limits;

    select count(*)
    into active_cover_images
    from public.card_cover_images image
    where image.card_id = target_card_id
      and image.archived_at is null;

    if active_cover_images >= coalesce(allowed_cover_images, 1) then
      return false;
    end if;

    return not exists (
      select 1
      from storage.objects object
      where object.bucket_id = 'digital-card-media'
        and (storage.foldername(object.name))[1] = parts[1]
        and (storage.foldername(object.name))[2] = parts[2]
        and (storage.foldername(object.name))[3] = 'cover'
        and object.name <> object_name
        and not exists (
          select 1
          from public.card_cover_images image
          where image.card_id = target_card_id
            and image.object_path = object.name
        )
        and object.name is distinct from locked_reference
    );
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

drop policy if exists "Published card media is publicly readable" on storage.objects;
create policy "Published card media is publicly readable"
on storage.objects
as permissive
for select
to anon, authenticated
using (
  bucket_id = 'digital-card-media'
  and storage.allow_any_operation(array[
    'object.get_authenticated_info',
    'object.get_authenticated',
    'storage.object.sign'
  ])
  and array_length(storage.foldername(name), 1) = 3
  and (storage.foldername(name))[3] = any(array['profile','logo','cover'])
  and storage.filename(name) ~*
    '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
  and exists (
    select 1
    from public.digital_cards card
    where card.id::text = (storage.foldername(objects.name))[2]
      and card.owner_id::text = (storage.foldername(objects.name))[1]
      and card.status = 'published'
      and (
        ((storage.foldername(objects.name))[3] = 'profile' and card.photo_url = objects.name)
        or ((storage.foldername(objects.name))[3] = 'logo' and card.logo_url = objects.name)
        or ((storage.foldername(objects.name))[3] = 'cover' and (
          card.cover_url = objects.name
          or exists (
            select 1
            from public.card_cover_images image
            where image.card_id = card.id
              and image.object_path = objects.name
              and image.archived_at is null
          )
        ))
      )
  )
);

update public.card_cover_images image
set archived_at = now(),
    download_until = now() + interval '30 days',
    updated_at = now()
from public.digital_cards card
where image.card_id = card.id
  and image.archived_at is null
  and (
    image.object_path not like card.owner_id::text || '/' || card.id::text || '/cover/%'
    or storage.filename(image.object_path) !~*
      '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\.(jpg|jpeg|png|webp)$'
  );

insert into public.card_cover_images(card_id, object_path, position)
select
  card.id,
  card.cover_url,
  coalesce((
    select max(image.position) + 1
    from public.card_cover_images image
    where image.card_id = card.id
      and image.archived_at is null
  ), 0)
from public.digital_cards card
where card.cover_url is not null
  and nullif(btrim(card.cover_url),'') is not null
  and not exists (
    select 1
    from public.card_cover_images image
    where image.card_id = card.id
      and image.object_path = card.cover_url
      and image.archived_at is null
  );

with ordered as (
  select
    image.id,
    row_number() over (
      partition by image.card_id
      order by case when image.object_path = card.cover_url then 0 else 1 end,
               image.position,
               image.created_at,
               image.id
    ) - 1 as new_position
  from public.card_cover_images image
  join public.digital_cards card on card.id = image.card_id
  where image.archived_at is null
)
update public.card_cover_images image
set position = ordered.new_position,
    updated_at = now()
from ordered
where image.id = ordered.id
  and image.position is distinct from ordered.new_position;
