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
