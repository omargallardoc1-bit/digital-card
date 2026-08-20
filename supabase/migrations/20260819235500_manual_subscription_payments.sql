-- Audited manual payment + renewal flow for superadministration.
-- No payment gateway is invoked here; this records an already-confirmed payment.

create table if not exists public.subscription_payment_events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  subscription_id uuid not null references public.organization_subscriptions(id) on delete cascade,
  amount numeric(12,2) not null check (amount > 0),
  currency text not null check (currency ~ '^[A-Z]{3}$'),
  payment_provider text not null check (char_length(payment_provider) between 1 and 80),
  external_reference text not null check (char_length(external_reference) between 1 and 120),
  paid_at timestamptz not null,
  old_status text not null,
  new_status text not null,
  old_expires_at timestamptz,
  new_expires_at timestamptz not null,
  reason text not null check (char_length(reason) between 1 and 500),
  recorded_by uuid not null,
  created_at timestamptz not null default statement_timestamp()
);

create unique index if not exists subscription_payment_events_provider_reference_uq
  on public.subscription_payment_events (lower(payment_provider), external_reference);
create index if not exists subscription_payment_events_subscription_created_idx
  on public.subscription_payment_events (subscription_id, created_at desc);

alter table public.subscription_payment_events enable row level security;
revoke all on table public.subscription_payment_events from anon, authenticated;

create or replace function public.record_manual_subscription_payment(
  actor_user_id uuid,
  target_subscription_id uuid,
  expected_status text,
  expected_expires_at timestamptz,
  payment_amount numeric,
  payment_currency text,
  payment_provider text,
  external_reference text,
  paid_at timestamptz,
  new_expires_at timestamptz,
  change_reason text
)
returns table(
  payment_id uuid,
  subscription_id uuid,
  organization_id uuid,
  old_status text,
  subscription_status text,
  old_expires_at timestamptz,
  expires_at timestamptz,
  recorded_by uuid
)
language plpgsql
security definer
set search_path=pg_catalog
as $$
declare
  s public.organization_subscriptions%rowtype;
  normalized_currency text;
  normalized_provider text;
  normalized_reference text;
  normalized_reason text;
  p_id uuid;
begin
  if private.platform_admin_role(actor_user_id) is distinct from 'superadmin' then
    raise exception using errcode='42501',message='No tienes autorización de administración de plataforma.';
  end if;

  normalized_currency := upper(btrim(payment_currency));
  normalized_provider := lower(btrim(payment_provider));
  normalized_reference := btrim(external_reference);
  normalized_reason := btrim(change_reason);

  if payment_amount is null or payment_amount <= 0 then
    raise exception using errcode='22023',message='El importe pagado debe ser mayor que cero.';
  end if;
  if normalized_currency !~ '^[A-Z]{3}$' then
    raise exception using errcode='22023',message='La moneda debe tener un código ISO de 3 letras.';
  end if;
  if char_length(normalized_provider) not between 1 and 80 or char_length(normalized_reference) not between 1 and 120 then
    raise exception using errcode='22023',message='Proveedor o referencia de pago no válidos.';
  end if;
  if char_length(normalized_reason) not between 1 and 500 then
    raise exception using errcode='22023',message='El motivo es obligatorio y debe tener máximo 500 caracteres.';
  end if;
  if paid_at is null or paid_at > statement_timestamp() + interval '5 minutes' then
    raise exception using errcode='22023',message='La fecha de pago no es válida.';
  end if;
  if new_expires_at is null then
    raise exception using errcode='22023',message='El nuevo vencimiento es obligatorio.';
  end if;

  select * into s
  from public.organization_subscriptions
  where id=target_subscription_id
  for update;
  if not found then
    raise exception using errcode='P0002',message='No se encontró la suscripción.';
  end if;

  if s.status not in ('active','past_due') then
    raise exception using errcode='22023',message='Solo se pueden renovar suscripciones activas o vencidas por pago.';
  end if;
  if s.status is distinct from expected_status or s.expires_at is distinct from expected_expires_at then
    raise exception using errcode='40001',message='La suscripción cambió. Actualiza los datos e intenta nuevamente.';
  end if;
  if new_expires_at <= greatest(coalesce(s.expires_at, '-infinity'::timestamptz), statement_timestamp()) then
    raise exception using errcode='22023',message='El nuevo vencimiento debe ser posterior al vencimiento actual y al momento presente.';
  end if;

  begin
    insert into public.subscription_payment_events(
      organization_id,subscription_id,amount,currency,payment_provider,external_reference,
      paid_at,old_status,new_status,old_expires_at,new_expires_at,reason,recorded_by
    ) values(
      s.organization_id,s.id,payment_amount,normalized_currency,normalized_provider,normalized_reference,
      paid_at,s.status,'active',s.expires_at,new_expires_at,normalized_reason,actor_user_id
    ) returning id into p_id;
  exception when unique_violation then
    raise exception using errcode='22023',message='Ya existe un pago con ese proveedor y referencia.';
  end;

  update public.organization_subscriptions
  set status='active', expires_at=new_expires_at, updated_at=statement_timestamp()
  where id=s.id;

  insert into public.organization_subscription_terms_audit(
    organization_id,subscription_id,old_starts_at,new_starts_at,
    old_expires_at,new_expires_at,old_renewal_type,new_renewal_type,
    change_reason,changed_at,changed_by
  ) values(
    s.organization_id,s.id,s.starts_at,s.starts_at,
    s.expires_at,new_expires_at,s.renewal_type,s.renewal_type,
    'Renovación pagada: '||normalized_reason,statement_timestamp(),actor_user_id
  );

  insert into public.organization_subscription_commercial_audit(
    organization_id,subscription_id,old_plan_id,new_plan_id,old_status,new_status,
    change_reason,changed_at,changed_by,actor_kind
  ) values(
    s.organization_id,s.id,s.plan_id,s.plan_id,s.status,'active',
    'Pago confirmado y renovación: '||normalized_reason,statement_timestamp(),actor_user_id,'user'
  );

  return query select p_id,s.id,s.organization_id,s.status,'active'::text,s.expires_at,new_expires_at,actor_user_id;
end;
$$;

revoke all on function public.record_manual_subscription_payment(uuid,uuid,text,timestamptz,numeric,text,text,text,timestamptz,timestamptz,text) from public,anon,authenticated;
grant execute on function public.record_manual_subscription_payment(uuid,uuid,text,timestamptz,numeric,text,text,text,timestamptz,timestamptz,text) to service_role;

create or replace function public.list_subscription_payment_events(
  actor_user_id uuid,
  target_subscription_id uuid,
  page integer default 1,
  page_size integer default 25
)
returns table(
  id uuid,
  amount numeric,
  currency text,
  payment_provider text,
  external_reference text,
  paid_at timestamptz,
  old_status text,
  new_status text,
  old_expires_at timestamptz,
  new_expires_at timestamptz,
  reason text,
  recorded_by uuid,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path=pg_catalog
as $$
begin
  if private.platform_admin_role(actor_user_id) is distinct from 'superadmin' then
    raise exception using errcode='42501',message='No tienes autorización de administración de plataforma.';
  end if;
  if page<1 or page_size<1 or page_size>100 then
    raise exception using errcode='22023',message='La paginación no es válida.';
  end if;
  return query
  select p.id,p.amount,p.currency,p.payment_provider,p.external_reference,p.paid_at,
         p.old_status,p.new_status,p.old_expires_at,p.new_expires_at,p.reason,p.recorded_by,p.created_at,
         count(*) over()
  from public.subscription_payment_events p
  where p.subscription_id=target_subscription_id
  order by p.created_at desc,p.id desc
  limit page_size offset ((page-1)*page_size);
end;
$$;

revoke all on function public.list_subscription_payment_events(uuid,uuid,integer,integer) from public,anon,authenticated;
grant execute on function public.list_subscription_payment_events(uuid,uuid,integer,integer) to service_role;
