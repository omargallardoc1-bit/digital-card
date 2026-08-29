alter table public.card_events
  drop constraint if exists card_events_event_type_check;

alter table public.card_events
  add constraint card_events_event_type_check
  check (event_type = any (array[
    'view'::text,
    'whatsapp_click'::text,
    'call_click'::text,
    'email_click'::text,
    'website_click'::text,
    'lead_created'::text,
    'referral_click'::text
  ]));

create or replace function public.track_public_referral_click(
  target_card_id uuid,
  event_source text default 'public_card'
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if event_source not in ('public_card','qr') then
    raise exception 'invalid source';
  end if;

  if not exists (
    select 1
    from public.digital_cards
    where id = target_card_id
      and status = 'published'
  ) then
    return false;
  end if;

  insert into public.card_events(card_id,event_type,metadata)
  values(target_card_id,'referral_click',jsonb_build_object('source',event_source));

  return true;
end;
$$;

revoke all on function public.track_public_referral_click(uuid,text) from public;
grant execute on function public.track_public_referral_click(uuid,text) to anon, authenticated;

comment on function public.track_public_referral_click(uuid,text) is
  'Public, narrowly-scoped referral click tracker for published cards. Does not award rewards or modify balances.';
