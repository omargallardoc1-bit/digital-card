-- Processing rules for verified Stripe invoice webhooks.
-- Only international Stripe subscriptions can be changed by these functions.

alter table public.subscription_payment_events
  add column if not exists actor_kind text not null default 'user';

alter table public.subscription_payment_events
  alter column recorded_by drop not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.subscription_payment_events'::regclass
      and conname='subscription_payment_events_actor_kind_check'
  ) then
    alter table public.subscription_payment_events
      add constraint subscription_payment_events_actor_kind_check
      check (actor_kind in ('user','system'));
  end if;
end $$;

alter table public.organization_subscription_terms_audit
  add column if not exists actor_kind text not null default 'user';

alter table public.organization_subscription_terms_audit
  alter column changed_by drop not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid='public.organization_subscription_terms_audit'::regclass
      and conname='organization_subscription_terms_audit_actor_kind_check'
  ) then
    alter table public.organization_subscription_terms_audit
      add constraint organization_subscription_terms_audit_actor_kind_check
      check (actor_kind in ('user','system'));
  end if;
end $$;

create or replace function public.mark_payment_provider_webhook_result(
  target_webhook_event_id uuid,
  result_status text,
  result_error text default null
)
returns void
language plpgsql
security definer
set search_path=pg_catalog
as $$
begin
  if result_status not in ('processed','ignored','failed') then
    raise exception using errcode='22023',message='Estado de procesamiento no válido.';
  end if;

  update public.payment_provider_webhook_events
  set processing_status=result_status,
      processed_at=statement_timestamp(),
      processing_error=case when result_status='failed' then left(result_error,2000) else null end
  where id=target_webhook_event_id;

  if not found then
    raise exception using errcode='P0002',message='No se encontró el evento de webhook.';
  end if;
end;
$$;

revoke all on function public.mark_payment_provider_webhook_result(uuid,text,text) from public,anon,authenticated;
grant execute on function public.mark_payment_provider_webhook_result(uuid,text,text) to service_role;

create or replace function public.process_stripe_invoice_webhook(
  target_webhook_event_id uuid,
  invoice_id text,
  stripe_subscription_id text,
  payment_amount numeric,
  payment_currency text,
  payment_at timestamptz,
  invoice_period_end timestamptz
)
returns table(
  processing_status text,
  subscription_id uuid,
  old_status text,
  new_status text,
  old_expires_at timestamptz,
  new_expires_at timestamptz
)
language plpgsql
security definer
set search_path=pg_catalog
as $$
declare
  w public.payment_provider_webhook_events%rowtype;
  s public.organization_subscriptions%rowtype;
  target_status text;
  target_expiry timestamptz;
  normalized_currency text;
  paid_amount numeric;
begin
  select * into w
  from public.payment_provider_webhook_events
  where id=target_webhook_event_id
  for update;

  if not found then
    raise exception using errcode='P0002',message='No se encontró el evento de webhook.';
  end if;

  if w.provider <> 'stripe' then
    raise exception using errcode='22023',message='El evento no pertenece a Stripe.';
  end if;

  if w.processing_status in ('processed','ignored') then
    return query select w.processing_status,null::uuid,null::text,null::text,null::timestamptz,null::timestamptz;
    return;
  end if;

  if w.event_type not in ('invoice.paid','invoice.payment_failed') then
    update public.payment_provider_webhook_events
    set processing_status='ignored',processed_at=statement_timestamp(),processing_error=null
    where id=w.id;
    return query select 'ignored'::text,null::uuid,null::text,null::text,null::timestamptz,null::timestamptz;
    return;
  end if;

  if stripe_subscription_id is null or btrim(stripe_subscription_id)='' then
    update public.payment_provider_webhook_events
    set processing_status='ignored',processed_at=statement_timestamp(),processing_error=null
    where id=w.id;
    return query select 'ignored'::text,null::uuid,null::text,null::text,null::timestamptz,null::timestamptz;
    return;
  end if;

  select * into s
  from public.organization_subscriptions
  where payment_provider='stripe'
    and external_subscription_id=btrim(stripe_subscription_id)
  for update;

  if not found then
    update public.payment_provider_webhook_events
    set processing_status='ignored',processed_at=statement_timestamp(),processing_error=null
    where id=w.id;
    return query select 'ignored'::text,null::uuid,null::text,null::text,null::timestamptz,null::timestamptz;
    return;
  end if;

  if s.billing_market <> 'international' then
    raise exception using errcode='22023',message='Stripe solo puede modificar suscripciones internacionales.';
  end if;

  if w.event_type='invoice.payment_failed' then
    target_status:='past_due';
    update public.organization_subscriptions
    set status=target_status,
        last_payment_status='failed',
        updated_at=statement_timestamp()
    where id=s.id;

    if s.status is distinct from target_status then
      insert into public.organization_subscription_commercial_audit(
        organization_id,subscription_id,old_plan_id,new_plan_id,old_status,new_status,
        change_reason,changed_at,changed_by,actor_kind
      ) values(
        s.organization_id,s.id,s.plan_id,s.plan_id,s.status,target_status,
        'Stripe: invoice.payment_failed',statement_timestamp(),null,'system'
      );
    end if;

    update public.payment_provider_webhook_events
    set processing_status='processed',processed_at=statement_timestamp(),processing_error=null
    where id=w.id;

    return query select 'processed'::text,s.id,s.status,target_status,s.expires_at,s.expires_at;
    return;
  end if;

  if invoice_id is null or btrim(invoice_id)='' then
    raise exception using errcode='22023',message='La factura de Stripe no tiene identificador.';
  end if;
  normalized_currency:=upper(btrim(payment_currency));
  paid_amount:=coalesce(payment_amount,0);
  if paid_amount < 0 or normalized_currency !~ '^[A-Z]{3}$' or payment_at is null then
    raise exception using errcode='22023',message='Los datos de pago de la factura no son válidos.';
  end if;

  target_status:='active';
  target_expiry:=greatest(
    coalesce(s.expires_at,'-infinity'::timestamptz),
    coalesce(invoice_period_end,s.expires_at,statement_timestamp())
  );

  update public.organization_subscriptions
  set status=target_status,
      expires_at=target_expiry,
      last_payment_status='paid',
      last_payment_at=payment_at,
      updated_at=statement_timestamp()
  where id=s.id;

  if paid_amount > 0 then
    insert into public.subscription_payment_events(
      organization_id,subscription_id,amount,currency,payment_provider,external_reference,
      paid_at,old_status,new_status,old_expires_at,new_expires_at,reason,recorded_by,actor_kind
    ) values(
      s.organization_id,s.id,paid_amount,normalized_currency,'stripe',btrim(invoice_id),
      payment_at,s.status,target_status,s.expires_at,target_expiry,
      'Stripe invoice.paid',null,'system'
    ) on conflict do nothing;
  end if;

  if s.status is distinct from target_status then
    insert into public.organization_subscription_commercial_audit(
      organization_id,subscription_id,old_plan_id,new_plan_id,old_status,new_status,
      change_reason,changed_at,changed_by,actor_kind
    ) values(
      s.organization_id,s.id,s.plan_id,s.plan_id,s.status,target_status,
      'Stripe: invoice.paid',statement_timestamp(),null,'system'
    );
  end if;

  if s.expires_at is distinct from target_expiry then
    insert into public.organization_subscription_terms_audit(
      organization_id,subscription_id,old_starts_at,new_starts_at,
      old_expires_at,new_expires_at,old_renewal_type,new_renewal_type,
      change_reason,changed_at,changed_by,actor_kind
    ) values(
      s.organization_id,s.id,s.starts_at,s.starts_at,
      s.expires_at,target_expiry,s.renewal_type,s.renewal_type,
      'Stripe: invoice.paid',statement_timestamp(),null,'system'
    );
  end if;

  update public.payment_provider_webhook_events
  set processing_status='processed',processed_at=statement_timestamp(),processing_error=null
  where id=w.id;

  return query select 'processed'::text,s.id,s.status,target_status,s.expires_at,target_expiry;
end;
$$;

revoke all on function public.process_stripe_invoice_webhook(uuid,text,text,numeric,text,timestamptz,timestamptz) from public,anon,authenticated;
grant execute on function public.process_stripe_invoice_webhook(uuid,text,text,numeric,text,timestamptz,timestamptz) to service_role;
