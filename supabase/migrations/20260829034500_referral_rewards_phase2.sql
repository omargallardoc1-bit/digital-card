create table if not exists public.omlig_reward_products (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  simple_seller_commission numeric(12,2) not null default 0 check (simple_seller_commission >= 0),
  reward_rate numeric(6,5) not null default 0.50 check (reward_rate > 0 and reward_rate <= 1),
  currency text not null default 'MXN' check (currency ~ '^[A-Z]{3}$'),
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.referral_sales (
  id uuid primary key default gen_random_uuid(),
  external_order_id text not null unique,
  product_id uuid not null references public.omlig_reward_products(id),
  product_code_snapshot text not null,
  product_name_snapshot text not null,
  referral_code_snapshot text not null,
  source_card_id uuid not null references public.digital_cards(id),
  beneficiary_organization_id uuid references public.organizations(id),
  beneficiary_owner_id uuid not null,
  buyer_owner_id uuid,
  buyer_reference text,
  sale_amount numeric(12,2) check (sale_amount is null or sale_amount >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  payment_status text not null default 'pending' check (payment_status in ('pending','paid','refunded','cancelled')),
  base_commission_snapshot numeric(12,2) not null check (base_commission_snapshot >= 0),
  reward_rate_snapshot numeric(6,5) not null check (reward_rate_snapshot > 0 and reward_rate_snapshot <= 1),
  reward_amount_snapshot numeric(12,2) not null check (reward_amount_snapshot >= 0),
  paid_at timestamptz,
  reversed_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (buyer_owner_id is null or buyer_owner_id <> beneficiary_owner_id)
);

create table if not exists public.reward_ledger (
  id uuid primary key default gen_random_uuid(),
  referral_sale_id uuid not null unique references public.referral_sales(id) on delete restrict,
  beneficiary_organization_id uuid references public.organizations(id),
  beneficiary_owner_id uuid not null,
  source_card_id uuid not null references public.digital_cards(id),
  amount numeric(12,2) not null check (amount >= 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  status text not null default 'pending' check (status in ('pending','available','redeemed','reversed','expired')),
  available_at timestamptz,
  redeemed_at timestamptz,
  reversed_at timestamptz,
  reason text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists referral_sales_product_idx on public.referral_sales(product_id);
create index if not exists referral_sales_source_card_idx on public.referral_sales(source_card_id, created_at desc);
create index if not exists referral_sales_beneficiary_org_idx on public.referral_sales(beneficiary_organization_id, created_at desc) where beneficiary_organization_id is not null;
create index if not exists referral_sales_beneficiary_owner_idx on public.referral_sales(beneficiary_owner_id, created_at desc);
create index if not exists reward_ledger_source_card_idx on public.reward_ledger(source_card_id);
create index if not exists reward_ledger_beneficiary_org_idx on public.reward_ledger(beneficiary_organization_id, status, created_at desc) where beneficiary_organization_id is not null;
create index if not exists reward_ledger_beneficiary_owner_idx on public.reward_ledger(beneficiary_owner_id, status, created_at desc);

alter table public.omlig_reward_products enable row level security;
alter table public.referral_sales enable row level security;
alter table public.reward_ledger enable row level security;

create or replace function public.can_view_reward_beneficiary(target_org uuid, target_owner uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
    and (
      target_owner = auth.uid()
      or (
        target_org is not null
        and exists (
          select 1 from public.organization_members om
          where om.organization_id = target_org
            and om.user_id = auth.uid()
            and om.status = 'active'
        )
      )
    );
$$;
revoke all on function public.can_view_reward_beneficiary(uuid,uuid) from public;
grant execute on function public.can_view_reward_beneficiary(uuid,uuid) to authenticated;

create policy referral_sales_beneficiary_select
on public.referral_sales
for select
to authenticated
using (public.can_view_reward_beneficiary(beneficiary_organization_id, beneficiary_owner_id));

create policy reward_ledger_beneficiary_select
on public.reward_ledger
for select
to authenticated
using (public.can_view_reward_beneficiary(beneficiary_organization_id, beneficiary_owner_id));

create or replace function public.create_pending_referral_sale(
  p_external_order_id text,
  p_referral_code text,
  p_product_code text,
  p_sale_amount numeric default null,
  p_currency text default 'MXN',
  p_buyer_owner_id uuid default null,
  p_buyer_reference text default null,
  p_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existing uuid;
  v_product public.omlig_reward_products%rowtype;
  v_card public.digital_cards%rowtype;
  v_sale_id uuid;
  v_reward numeric(12,2);
begin
  if coalesce(trim(p_external_order_id),'') = '' then raise exception 'external_order_id required'; end if;
  if p_currency !~ '^[A-Z]{3}$' then raise exception 'invalid currency'; end if;

  select id into v_existing from public.referral_sales where external_order_id = p_external_order_id;
  if v_existing is not null then return v_existing; end if;

  select * into v_product from public.omlig_reward_products where code = p_product_code and active = true;
  if not found then raise exception 'unknown or inactive reward product'; end if;
  if v_product.simple_seller_commission <= 0 then raise exception 'seller commission is not configured'; end if;
  if v_product.currency <> p_currency then raise exception 'currency mismatch'; end if;

  select * into v_card from public.digital_cards where referral_code = lower(trim(p_referral_code)) and status = 'published';
  if not found then raise exception 'invalid referral code'; end if;
  if p_buyer_owner_id is not null and p_buyer_owner_id = v_card.owner_id then raise exception 'self referral is not allowed'; end if;

  v_reward := round(v_product.simple_seller_commission * v_product.reward_rate, 2);

  insert into public.referral_sales(
    external_order_id, product_id, product_code_snapshot, product_name_snapshot,
    referral_code_snapshot, source_card_id, beneficiary_organization_id, beneficiary_owner_id,
    buyer_owner_id, buyer_reference, sale_amount, currency, payment_status,
    base_commission_snapshot, reward_rate_snapshot, reward_amount_snapshot, metadata
  ) values (
    p_external_order_id, v_product.id, v_product.code, v_product.name,
    v_card.referral_code, v_card.id, v_card.organization_id, v_card.owner_id,
    p_buyer_owner_id, nullif(trim(p_buyer_reference),''), p_sale_amount, p_currency, 'pending',
    v_product.simple_seller_commission, v_product.reward_rate, v_reward, coalesce(p_metadata,'{}'::jsonb)
  ) returning id into v_sale_id;

  insert into public.reward_ledger(
    referral_sale_id, beneficiary_organization_id, beneficiary_owner_id, source_card_id,
    amount, currency, status, metadata
  ) values (
    v_sale_id, v_card.organization_id, v_card.owner_id, v_card.id,
    v_reward, p_currency, 'pending', jsonb_build_object('product_code',v_product.code)
  );

  return v_sale_id;
end;
$$;

create or replace function public.mark_referral_sale_paid(p_external_order_id text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_sale_id uuid;
begin
  update public.referral_sales
  set payment_status='paid', paid_at=coalesce(paid_at,now()), updated_at=now()
  where external_order_id=p_external_order_id and payment_status in ('pending','paid')
  returning id into v_sale_id;
  if v_sale_id is null then raise exception 'referral sale not found or cannot be paid'; end if;

  update public.reward_ledger
  set status='available', available_at=coalesce(available_at,now()), updated_at=now()
  where referral_sale_id=v_sale_id and status in ('pending','available');
  return v_sale_id;
end;
$$;

create or replace function public.reverse_referral_sale(p_external_order_id text, p_reason text default null)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_sale_id uuid;
begin
  update public.referral_sales
  set payment_status='refunded', reversed_at=coalesce(reversed_at,now()), updated_at=now()
  where external_order_id=p_external_order_id and payment_status in ('paid','refunded')
  returning id into v_sale_id;
  if v_sale_id is null then raise exception 'paid referral sale not found'; end if;

  update public.reward_ledger
  set status='reversed', reversed_at=coalesce(reversed_at,now()), reason=coalesce(nullif(trim(p_reason),''),reason), updated_at=now()
  where referral_sale_id=v_sale_id and status in ('available','reversed');
  return v_sale_id;
end;
$$;

revoke all on function public.create_pending_referral_sale(text,text,text,numeric,text,uuid,text,jsonb) from public, anon, authenticated;
revoke all on function public.mark_referral_sale_paid(text) from public, anon, authenticated;
revoke all on function public.reverse_referral_sale(text,text) from public, anon, authenticated;
grant execute on function public.create_pending_referral_sale(text,text,text,numeric,text,uuid,text,jsonb) to service_role;
grant execute on function public.mark_referral_sale_paid(text) to service_role;
grant execute on function public.reverse_referral_sale(text,text) to service_role;

create or replace view public.my_reward_summary
with (security_invoker=true)
as
select
  beneficiary_organization_id,
  beneficiary_owner_id,
  currency,
  count(*) filter (where status='pending') as pending_rewards,
  count(*) filter (where status='available') as available_rewards,
  count(*) filter (where status='redeemed') as redeemed_rewards,
  coalesce(sum(amount) filter (where status='pending'),0)::numeric(12,2) as pending_amount,
  coalesce(sum(amount) filter (where status='available'),0)::numeric(12,2) as available_amount,
  coalesce(sum(amount) filter (where status='redeemed'),0)::numeric(12,2) as redeemed_amount
from public.reward_ledger
group by beneficiary_organization_id, beneficiary_owner_id, currency;

grant select on public.my_reward_summary to authenticated;

insert into public.omlig_reward_products(code,name,simple_seller_commission,reward_rate,currency,active)
values
  ('mx_card_esencial','MX Business Card — Esencial',50.00,0.50,'MXN',true),
  ('mx_card_independiente','MX Business Card — Independiente',70.00,0.50,'MXN',true),
  ('mx_card_pyme','MX Business Card — PyME',90.00,0.50,'MXN',true),
  ('mx_card_empresarial','MX Business Card — Empresarial',110.00,0.50,'MXN',true)
on conflict (code) do update set
  name=excluded.name,
  simple_seller_commission=excluded.simple_seller_commission,
  reward_rate=excluded.reward_rate,
  currency=excluded.currency,
  active=excluded.active,
  updated_at=now();

comment on table public.omlig_reward_products is 'Internal OMLIG reward product catalog. Reward rate is applied to the simple seller commission.';
comment on table public.referral_sales is 'Referral-attributed sales with immutable commission and reward snapshots.';
comment on table public.reward_ledger is 'Reward entitlement ledger. A reward becomes available only after validated payment.';
