begin;

do $preflight$
begin
  if to_regclass('public.card_buttons') is null then
    raise exception 'Precondition failed: public.card_buttons does not exist';
  end if;

  if to_regclass('public.card_services') is null then
    raise exception 'Precondition failed: public.card_services does not exist';
  end if;

  if to_regclass('public.digital_cards') is null then
    raise exception 'Precondition failed: public.digital_cards does not exist';
  end if;

  if to_regprocedure('private.is_organization_member(uuid)') is null then
    raise exception 'Precondition failed: private.is_organization_member(uuid) does not exist';
  end if;

  if to_regprocedure('private.has_organization_role(uuid,text[])') is null then
    raise exception 'Precondition failed: private.has_organization_role(uuid,text[]) does not exist';
  end if;

  if not coalesce((
    select class.relrowsecurity
    from pg_catalog.pg_class as class
    join pg_catalog.pg_namespace as namespace on namespace.oid = class.relnamespace
    where namespace.nspname = 'public'
      and class.relname = 'card_buttons'
      and class.relkind = 'r'
  ), false) then
    raise exception 'Precondition failed: RLS is not enabled on public.card_buttons';
  end if;

  if not coalesce((
    select class.relrowsecurity
    from pg_catalog.pg_class as class
    join pg_catalog.pg_namespace as namespace on namespace.oid = class.relnamespace
    where namespace.nspname = 'public'
      and class.relname = 'card_services'
      and class.relkind = 'r'
  ), false) then
    raise exception 'Precondition failed: RLS is not enabled on public.card_services';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'card_buttons'
      and policyname = 'Public reads buttons of published cards'
      and cmd = 'SELECT'
  ) then
    raise exception 'Precondition failed: public card_buttons SELECT policy is missing';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'card_services'
      and policyname = 'Public reads services of published cards'
      and cmd = 'SELECT'
  ) then
    raise exception 'Precondition failed: public card_services SELECT policy is missing';
  end if;
end
$preflight$;

grant select
on table public.card_buttons, public.card_services
to anon, authenticated;

grant insert, update, delete
on table public.card_buttons, public.card_services
to authenticated;

drop policy if exists "Owners manage card buttons" on public.card_buttons;
drop policy if exists "Owners manage card services" on public.card_services;

drop policy if exists "Authenticated reads permitted card buttons" on public.card_buttons;
drop policy if exists "Authorized members insert card buttons" on public.card_buttons;
drop policy if exists "Authorized members update card buttons" on public.card_buttons;
drop policy if exists "Authorized members delete card buttons" on public.card_buttons;
drop policy if exists "Authenticated reads permitted card services" on public.card_services;
drop policy if exists "Authorized members insert card services" on public.card_services;
drop policy if exists "Authorized members update card services" on public.card_services;
drop policy if exists "Authorized members delete card services" on public.card_services;

create policy "Authenticated reads permitted card buttons"
on public.card_buttons
for select
to authenticated
using (
  exists (
    select 1 from public.digital_cards as card
    where card.id = card_buttons.card_id
      and (
        private.is_organization_member(card.organization_id)
        or (card.organization_id is null and card.owner_id = (select auth.uid()))
      )
  )
);

create policy "Authorized members insert card buttons"
on public.card_buttons
for insert
to authenticated
with check (
  exists (
    select 1 from public.digital_cards as card
    where card.id = card_buttons.card_id
      and (
        private.has_organization_role(card.organization_id, array['owner', 'admin', 'editor']::text[])
        or (card.organization_id is null and card.owner_id = (select auth.uid()))
      )
  )
);

create policy "Authorized members update card buttons"
on public.card_buttons
for update
to authenticated
using (
  exists (
    select 1 from public.digital_cards as card
    where card.id = card_buttons.card_id
      and (
        private.has_organization_role(card.organization_id, array['owner', 'admin', 'editor']::text[])
        or (card.organization_id is null and card.owner_id = (select auth.uid()))
      )
  )
)
with check (
  exists (
    select 1 from public.digital_cards as card
    where card.id = card_buttons.card_id
      and (
        private.has_organization_role(card.organization_id, array['owner', 'admin', 'editor']::text[])
        or (card.organization_id is null and card.owner_id = (select auth.uid()))
      )
  )
);

create policy "Authorized members delete card buttons"
on public.card_buttons
for delete
to authenticated
using (
  exists (
    select 1 from public.digital_cards as card
    where card.id = card_buttons.card_id
      and (
        private.has_organization_role(card.organization_id, array['owner', 'admin', 'editor']::text[])
        or (card.organization_id is null and card.owner_id = (select auth.uid()))
      )
  )
);

create policy "Authenticated reads permitted card services"
on public.card_services
for select
to authenticated
using (
  exists (
    select 1 from public.digital_cards as card
    where card.id = card_services.card_id
      and (
        private.is_organization_member(card.organization_id)
        or (card.organization_id is null and card.owner_id = (select auth.uid()))
      )
  )
);

create policy "Authorized members insert card services"
on public.card_services
for insert
to authenticated
with check (
  exists (
    select 1 from public.digital_cards as card
    where card.id = card_services.card_id
      and (
        private.has_organization_role(card.organization_id, array['owner', 'admin', 'editor']::text[])
        or (card.organization_id is null and card.owner_id = (select auth.uid()))
      )
  )
);

create policy "Authorized members update card services"
on public.card_services
for update
to authenticated
using (
  exists (
    select 1 from public.digital_cards as card
    where card.id = card_services.card_id
      and (
        private.has_organization_role(card.organization_id, array['owner', 'admin', 'editor']::text[])
        or (card.organization_id is null and card.owner_id = (select auth.uid()))
      )
  )
)
with check (
  exists (
    select 1 from public.digital_cards as card
    where card.id = card_services.card_id
      and (
        private.has_organization_role(card.organization_id, array['owner', 'admin', 'editor']::text[])
        or (card.organization_id is null and card.owner_id = (select auth.uid()))
      )
  )
);

create policy "Authorized members delete card services"
on public.card_services
for delete
to authenticated
using (
  exists (
    select 1 from public.digital_cards as card
    where card.id = card_services.card_id
      and (
        private.has_organization_role(card.organization_id, array['owner', 'admin', 'editor']::text[])
        or (card.organization_id is null and card.owner_id = (select auth.uid()))
      )
  )
);

do $postflight$
begin
  if not has_table_privilege('anon', 'public.card_buttons', 'SELECT') then
    raise exception 'Postcondition failed: anon lacks SELECT on card_buttons';
  end if;
  if not has_table_privilege('anon', 'public.card_services', 'SELECT') then
    raise exception 'Postcondition failed: anon lacks SELECT on card_services';
  end if;

  if has_table_privilege('anon', 'public.card_buttons', 'INSERT')
     or has_table_privilege('anon', 'public.card_buttons', 'UPDATE')
     or has_table_privilege('anon', 'public.card_buttons', 'DELETE')
     or has_table_privilege('anon', 'public.card_services', 'INSERT')
     or has_table_privilege('anon', 'public.card_services', 'UPDATE')
     or has_table_privilege('anon', 'public.card_services', 'DELETE') then
    raise exception 'Postcondition failed: anon received write privileges';
  end if;

  if not has_table_privilege('authenticated', 'public.card_buttons', 'SELECT')
     or not has_table_privilege('authenticated', 'public.card_buttons', 'INSERT')
     or not has_table_privilege('authenticated', 'public.card_buttons', 'UPDATE')
     or not has_table_privilege('authenticated', 'public.card_buttons', 'DELETE')
     or not has_table_privilege('authenticated', 'public.card_services', 'SELECT')
     or not has_table_privilege('authenticated', 'public.card_services', 'INSERT')
     or not has_table_privilege('authenticated', 'public.card_services', 'UPDATE')
     or not has_table_privilege('authenticated', 'public.card_services', 'DELETE') then
    raise exception 'Postcondition failed: authenticated component privileges are incomplete';
  end if;

  if exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'card_buttons'
      and policyname = 'Owners manage card buttons'
  ) or exists (
    select 1 from pg_catalog.pg_policies
    where schemaname = 'public'
      and tablename = 'card_services'
      and policyname = 'Owners manage card services'
  ) then
    raise exception 'Postcondition failed: a legacy administrative policy remains';
  end if;
end
$postflight$;

commit;
