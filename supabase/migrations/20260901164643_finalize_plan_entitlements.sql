-- Matriz comercial definitiva de MX Business Card.
-- Migración aditiva y no destructiva: no elimina ni recorta contenido existente.

begin;

update public.plans
set
  logo_image_enabled = true,
  cover_image_enabled = true,
  capabilities = capabilities || jsonb_build_object(
    'commercially_final', true,
    'configuration_status', 'final_2026_09',
    'cover_images_limit', case code
      when 'conecta-card-esencial' then 1
      when 'conecta-card-independiente' then 3
      when 'conecta-card-pyme' then 3
      when 'conecta-card-empresarial' then 5
    end,
    'services_limit', case code
      when 'conecta-card-esencial' then 0
      when 'conecta-card-independiente' then 5
      when 'conecta-card-pyme' then 10
      when 'conecta-card-empresarial' then 20
    end,
    'audio_enabled', code <> 'conecta-card-esencial',
    'audio_max_seconds', case when code = 'conecta-card-esencial' then 0 else 30 end,
    'mini_crm_enabled', code <> 'conecta-card-esencial',
    'appointments_enabled', code in ('conecta-card-pyme','conecta-card-empresarial'),
    'cover_interval_ms', 5000,
    'cover_transition_ms', 700,
    'downgrade_download_days', 30
  ),
  updated_at = now()
where code in (
  'conecta-card-esencial',
  'conecta-card-independiente',
  'conecta-card-pyme',
  'conecta-card-empresarial'
);

create table if not exists public.card_cover_images (
  id uuid primary key default gen_random_uuid(),
  card_id uuid not null references public.digital_cards(id) on delete cascade,
  object_path text not null,
  position integer not null default 0 check (position >= 0),
  archived_at timestamptz,
  download_until timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint card_cover_images_path_not_blank check (nullif(btrim(object_path),'') is not null),
  constraint card_cover_images_download_window check (
    (archived_at is null and download_until is null)
    or (archived_at is not null and download_until is not null and download_until > archived_at)
  )
);

-- Compatibilidad con proyectos anteriores a la asignación de tipo por tarjeta.
-- En producción la columna ya existe; en laboratorio se agrega sin alterar filas actuales.
alter table public.digital_cards add column if not exists plan_id uuid;
alter table public.digital_cards add column if not exists audio_url text;
alter table public.digital_cards add column if not exists audio_duration_seconds integer;
alter table public.digital_cards add column if not exists audio_loop boolean not null default false;
alter table public.digital_cards add column if not exists audio_max_seconds integer not null default 30;

do $plan_id_fk$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.digital_cards'::regclass
      and conname='digital_cards_plan_id_fkey'
  ) then
    alter table public.digital_cards
      add constraint digital_cards_plan_id_fkey
      foreign key(plan_id) references public.plans(id)
      on update restrict on delete restrict;
  end if;
end;
$plan_id_fk$;

create index if not exists digital_cards_plan_id_idx on public.digital_cards(plan_id);

create unique index if not exists card_cover_images_active_position_uidx
on public.card_cover_images(card_id, position)
where archived_at is null;

create unique index if not exists card_cover_images_active_path_uidx
on public.card_cover_images(card_id, object_path)
where archived_at is null;

create index if not exists card_cover_images_download_until_idx
on public.card_cover_images(download_until)
where archived_at is not null;

insert into public.card_cover_images(card_id, object_path, position)
select card.id, card.cover_url, 0
from public.digital_cards card
where card.cover_url is not null
  and nullif(btrim(card.cover_url),'') is not null
  and not exists (
    select 1 from public.card_cover_images image
    where image.card_id=card.id and image.object_path=card.cover_url
  );

alter table public.card_cover_images enable row level security;

drop policy if exists "Public reads published active cover images" on public.card_cover_images;
create policy "Public reads published active cover images"
on public.card_cover_images for select
to anon, authenticated
using (
  archived_at is null
  and exists (
    select 1 from public.digital_cards card
    where card.id=card_cover_images.card_id and card.status='published'
  )
  or exists (
    select 1 from public.digital_cards card
    join public.organization_members member on member.organization_id=card.organization_id
    where card.id=card_cover_images.card_id
      and member.user_id=(select auth.uid()) and member.status='active'
  )
);

revoke insert, update, delete on public.card_cover_images from anon, authenticated;
grant select on public.card_cover_images to anon, authenticated;

create or replace function private.card_content_limits(target_card_id uuid)
returns table(
  plan_code text,
  cover_images_limit integer,
  services_limit integer,
  audio_enabled boolean,
  audio_max_seconds integer,
  mini_crm_enabled boolean,
  appointments_enabled boolean
)
language sql stable security definer set search_path='pg_catalog'
as $function$
  select
    plan.code,
    coalesce((plan.capabilities->>'cover_images_limit')::integer,1),
    coalesce((plan.capabilities->>'services_limit')::integer,0),
    coalesce((plan.capabilities->>'audio_enabled')::boolean,false),
    coalesce((plan.capabilities->>'audio_max_seconds')::integer,0),
    coalesce((plan.capabilities->>'mini_crm_enabled')::boolean,false),
    coalesce((plan.capabilities->>'appointments_enabled')::boolean,false)
  from public.digital_cards card
  left join lateral private.get_effective_plan(card.organization_id) organization_plan on true
  join public.plans plan on plan.id=coalesce(card.plan_id,organization_plan.plan_id)
  where card.id=target_card_id;
$function$;

revoke all on function private.card_content_limits(uuid) from public, anon, authenticated;

create or replace function public.get_card_content_limits(target_card_id uuid)
returns table(
  plan_code text,
  cover_images_limit integer,
  services_limit integer,
  audio_enabled boolean,
  audio_max_seconds integer,
  mini_crm_enabled boolean,
  appointments_enabled boolean
)
language plpgsql stable security definer set search_path='pg_catalog'
as $function$
begin
  if (select auth.uid()) is null then
    raise exception using errcode='42501', message='Autenticación requerida.';
  end if;
  if not exists (
    select 1 from public.digital_cards card
    join public.organization_members member on member.organization_id=card.organization_id
    where card.id=target_card_id and member.user_id=(select auth.uid()) and member.status='active'
  ) then
    raise exception using errcode='42501', message='No tienes acceso a esta tarjeta.';
  end if;
  return query select * from private.card_content_limits(target_card_id);
end;
$function$;

revoke all on function public.get_card_content_limits(uuid) from public, anon, service_role;
grant execute on function public.get_card_content_limits(uuid) to authenticated;

create or replace function private.enforce_card_service_limit()
returns trigger language plpgsql security definer set search_path='pg_catalog'
as $function$
declare allowed integer; current_count integer;
begin
  select limits.services_limit into allowed from private.card_content_limits(new.card_id) limits;
  if allowed is null then raise exception using errcode='42501',message='La tarjeta no tiene un plan utilizable.'; end if;
  select count(*) into current_count from public.card_services service where service.card_id=new.card_id;
  if current_count >= allowed then
    raise exception using errcode='P0001',message=format('El plan permite hasta %s productos o servicios.',allowed);
  end if;
  return new;
end;
$function$;

drop trigger if exists enforce_card_service_limit on public.card_services;
create trigger enforce_card_service_limit before insert on public.card_services
for each row execute function private.enforce_card_service_limit();

create or replace function public.add_card_cover_image(target_card_id uuid, object_path text)
returns public.card_cover_images
language plpgsql security definer set search_path='pg_catalog'
as $function$
declare allowed integer; used integer; normalized text; created public.card_cover_images%rowtype;
begin
  if (select auth.uid()) is null then raise exception using errcode='42501',message='Autenticación requerida.'; end if;
  normalized:=btrim(coalesce(object_path,''));
  if normalized='' or char_length(normalized)>1024 then raise exception using errcode='22023',message='La referencia de portada no es válida.'; end if;
  if not exists (
    select 1 from public.digital_cards card join public.organization_members member on member.organization_id=card.organization_id
    where card.id=target_card_id and member.user_id=(select auth.uid()) and member.status='active' and member.role in ('owner','admin','editor')
  ) then raise exception using errcode='42501',message='No tienes permiso para modificar esta tarjeta.'; end if;
  select limits.cover_images_limit into allowed from private.card_content_limits(target_card_id) limits;
  select count(*) into used from public.card_cover_images image where image.card_id=target_card_id and image.archived_at is null;
  if used>=allowed then raise exception using errcode='P0001',message=format('El plan permite hasta %s fotografías de portada.',allowed); end if;
  insert into public.card_cover_images(card_id,object_path,position)
  values(target_card_id,normalized,used) returning * into created;
  if used=0 then update public.digital_cards set cover_url=normalized where id=target_card_id; end if;
  return created;
end;
$function$;

revoke all on function public.add_card_cover_image(uuid,text) from public, anon, service_role;
grant execute on function public.add_card_cover_image(uuid,text) to authenticated;

create or replace function public.archive_card_cover_image(target_image_id uuid)
returns public.card_cover_images
language plpgsql security definer set search_path='pg_catalog'
as $function$
declare existing public.card_cover_images%rowtype; result public.card_cover_images%rowtype; replacement text;
begin
  select image.* into existing from public.card_cover_images image where image.id=target_image_id for update;
  if not found then raise exception using errcode='P0002',message='La fotografía no existe.'; end if;
  if not exists (
    select 1 from public.digital_cards card join public.organization_members member on member.organization_id=card.organization_id
    where card.id=existing.card_id and member.user_id=(select auth.uid()) and member.status='active' and member.role in ('owner','admin','editor')
  ) then raise exception using errcode='42501',message='No tienes permiso para modificar esta tarjeta.'; end if;
  update public.card_cover_images set archived_at=now(),download_until=now()+interval '30 days',updated_at=now()
  where id=target_image_id returning * into result;
  with ordered as (
    select id,row_number() over(order by position,created_at,id)-1 new_position
    from public.card_cover_images where card_id=existing.card_id and archived_at is null
  ) update public.card_cover_images image set position=ordered.new_position,updated_at=now() from ordered where image.id=ordered.id;
  select object_path into replacement from public.card_cover_images
  where card_id=existing.card_id and archived_at is null order by position limit 1;
  update public.digital_cards set cover_url=replacement where id=existing.card_id;
  return result;
end;
$function$;

revoke all on function public.archive_card_cover_image(uuid) from public, anon, service_role;
grant execute on function public.archive_card_cover_image(uuid) to authenticated;

-- Existing audio is preserved. New or replaced audio must respect the final plan matrix.
create or replace function private.enforce_card_audio_plan()
returns trigger language plpgsql security definer set search_path='pg_catalog'
as $function$
declare limits record;
begin
  if new.audio_url is not distinct from old.audio_url and new.audio_duration_seconds is not distinct from old.audio_duration_seconds then return new; end if;
  select * into limits from private.card_content_limits(new.id);
  if new.audio_url is not null and limits.audio_enabled is not true then raise exception using errcode='42501',message='El plan no incluye audio.'; end if;
  if new.audio_duration_seconds is not null and new.audio_duration_seconds>limits.audio_max_seconds then
    raise exception using errcode='22023',message=format('El audio puede durar hasta %s segundos.',limits.audio_max_seconds);
  end if;
  return new;
end;
$function$;

drop trigger if exists enforce_card_audio_plan on public.digital_cards;
create trigger enforce_card_audio_plan before update of audio_url,audio_duration_seconds on public.digital_cards
for each row execute function private.enforce_card_audio_plan();

-- Ajusta solo tarjetas sin audio o con audio dentro del nuevo límite; jamás invalida audio existente.
update public.digital_cards card
set audio_max_seconds=30
where (card.audio_duration_seconds is null or card.audio_duration_seconds<=30)
  and exists (
    select 1 from private.card_content_limits(card.id) limits where limits.audio_enabled=true
  );

commit;
