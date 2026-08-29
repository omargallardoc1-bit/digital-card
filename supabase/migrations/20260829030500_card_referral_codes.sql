alter table public.digital_cards add column if not exists referral_code text;

update public.digital_cards
set referral_code = lower(encode(gen_random_bytes(10), 'hex'))
where referral_code is null;

alter table public.digital_cards
  alter column referral_code set default lower(encode(gen_random_bytes(10), 'hex')),
  alter column referral_code set not null;

create unique index if not exists digital_cards_referral_code_uidx
  on public.digital_cards (referral_code);

alter table public.digital_cards
  drop constraint if exists digital_cards_referral_code_format_chk;

alter table public.digital_cards
  add constraint digital_cards_referral_code_format_chk
  check (referral_code ~ '^[0-9a-f]{20}$');

comment on column public.digital_cards.referral_code is
  'Opaque referral code used to attribute OMLIG traffic and rewards back to the source card.';
