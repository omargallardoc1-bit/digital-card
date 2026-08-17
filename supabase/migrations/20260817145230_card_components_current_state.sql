-- Snapshot del estado efectivo de botones, servicios y redes sociales.
--
-- Dependencias versionadas en 3A y deliberadamente no duplicadas:
--   public.digital_cards (incluidos owner_id y organization_id)
--   public.organizations
--   public.organization_members
--   private.is_organization_member(uuid)
--   private.has_organization_role(uuid, text[])
--
-- No existen RPC específicas para estos tres componentes en el estado
-- remoto actual. Las policies legacy basadas en owner_id se preservan
-- exactamente y no se corrigen en esta fase de snapshot.

begin;

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

create policy "Owners manage card buttons"
on public.card_buttons
as permissive
for all
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_buttons.card_id) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))
with check ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_buttons.card_id) AND (c.owner_id = ( SELECT auth.uid() AS uid))))));

create policy "Public reads buttons of published cards"
on public.card_buttons
as permissive
for select
to anon, authenticated
using (((enabled = true) AND (EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_buttons.card_id) AND (c.status = 'published'::text))))));

create policy "Owners manage card services"
on public.card_services
as permissive
for all
to authenticated
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_services.card_id) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))
with check ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = card_services.card_id) AND (c.owner_id = ( SELECT auth.uid() AS uid))))));

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

-- ACL efectivas del estado remoto. Se preservan incluso donde no existe
-- privilegio DML útil para las policies legacy.
revoke all privileges
on table public.card_buttons,
         public.card_services,
         public.card_socials
from public, anon, authenticated, service_role;

grant truncate, references, trigger, maintain
on table public.card_buttons,
         public.card_services
to anon, authenticated, service_role;

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

revoke all
on function public.card_services_set_updated_at()
from public, anon, authenticated, service_role;

commit;
