with unavailable_archived_covers as (
  select image.id
  from public.card_cover_images image
  join public.digital_cards card on card.id = image.card_id
  left join storage.objects object
    on object.bucket_id = 'digital-card-media'
   and object.name = image.object_path
  where image.archived_at is not null
    and image.download_until > now()
    and (
      object.id is null
      or image.object_path not like card.owner_id::text || '/' || image.card_id::text || '/cover/%'
    )
)
update public.card_cover_images image
set download_until = now(), updated_at = now()
from unavailable_archived_covers bad
where image.id = bad.id;

revoke execute on function public.set_card_media_reference(uuid,text,text) from public, anon;
grant execute on function public.set_card_media_reference(uuid,text,text) to authenticated;
