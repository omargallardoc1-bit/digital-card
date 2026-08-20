-- Stripe automatic billing foundation.
-- This migration adds durable provider identifiers and an idempotent webhook inbox.
-- It does NOT enable charging or create Stripe resources.

alter table public.organization_subscriptions
  add column if not exists external_customer_id text,
  add column if not exists last_payment_status text,
  add column if not exists last_payment_at timestamptz;

create unique index if not exists organization_subscriptions_provider_external_subscription_uq
  on public.organization_subscriptions (lower(payment_provider), external_subscription_id)
  where payment_provider is not null and external_subscription_id is not null;

create table if not exists public.payment_provider_webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null check (provider in ('stripe')),
  external_event_id text not null,
  event_type text not null,
  external_customer_id text,
  external_subscription_id text,
  livemode boolean not null default false,
  payload jsonb not null,
  received_at timestamptz not null default statement_timestamp(),
  processed_at timestamptz,
  processing_status text not null default 'received' check (processing_status in ('received','processed','ignored','failed')),
  processing_error text,
  constraint payment_provider_webhook_events_provider_event_uq unique(provider,external_event_id)
);

create index if not exists payment_provider_webhook_events_subscription_idx
  on public.payment_provider_webhook_events(provider,external_subscription_id,received_at desc);
create index if not exists payment_provider_webhook_events_status_idx
  on public.payment_provider_webhook_events(processing_status,received_at);

alter table public.payment_provider_webhook_events enable row level security;
revoke all on table public.payment_provider_webhook_events from anon,authenticated;

create or replace function public.ingest_payment_provider_webhook(
  provider_name text,
  event_id text,
  event_type_name text,
  customer_id text,
  subscription_id text,
  is_livemode boolean,
  event_payload jsonb
)
returns table(webhook_event_id uuid,inserted boolean)
language plpgsql
security definer
set search_path=pg_catalog
as $$
declare
  existing_id uuid;
  new_id uuid;
begin
  if provider_name <> 'stripe' then
    raise exception using errcode='22023',message='Proveedor de pago no soportado.';
  end if;
  if event_id is null or btrim(event_id)='' or event_type_name is null or btrim(event_type_name)='' or event_payload is null then
    raise exception using errcode='22023',message='El evento de pago no es válido.';
  end if;

  select id into existing_id
  from public.payment_provider_webhook_events
  where provider=provider_name and external_event_id=event_id;
  if existing_id is not null then
    return query select existing_id,false;
    return;
  end if;

  insert into public.payment_provider_webhook_events(
    provider,external_event_id,event_type,external_customer_id,external_subscription_id,livemode,payload
  ) values(
    provider_name,btrim(event_id),btrim(event_type_name),nullif(btrim(customer_id),''),nullif(btrim(subscription_id),''),coalesce(is_livemode,false),event_payload
  ) returning id into new_id;

  return query select new_id,true;
end;
$$;

revoke all on function public.ingest_payment_provider_webhook(text,text,text,text,text,boolean,jsonb) from public,anon,authenticated;
grant execute on function public.ingest_payment_provider_webhook(text,text,text,text,text,boolean,jsonb) to service_role;
