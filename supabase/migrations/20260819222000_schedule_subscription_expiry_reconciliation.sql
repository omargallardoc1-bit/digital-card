-- Scheduled subscription-expiry reconciliation.
-- This migration is intentionally self-contained and idempotent.
-- Automatic-renewal subscriptions are never changed by this reconciler.

create extension if not exists pg_cron;

-- Allow scheduled runs to be attributed to the system instead of a human UUID,
-- while preserving strict actor attribution through actor_kind constraints.
alter table public.subscription_reconciliation_runs alter column started_by drop not null;
alter table public.subscription_reconciliation_audit alter column reconciled_by drop not null;
alter table public.organization_subscription_commercial_audit alter column changed_by drop not null;

alter table public.subscription_reconciliation_runs add column if not exists actor_kind text not null default 'user';
alter table public.subscription_reconciliation_audit add column if not exists actor_kind text not null default 'user';
alter table public.organization_subscription_commercial_audit add column if not exists actor_kind text not null default 'user';

do $$
begin
  if exists (select 1 from pg_constraint where conrelid='public.subscription_reconciliation_runs'::regclass and conname='subscription_reconciliation_runs_mode_check') then
    alter table public.subscription_reconciliation_runs drop constraint subscription_reconciliation_runs_mode_check;
  end if;
  if exists (select 1 from pg_constraint where conrelid='public.subscription_reconciliation_runs'::regclass and conname='subscription_reconciliation_runs_actor_kind_check') then
    alter table public.subscription_reconciliation_runs drop constraint subscription_reconciliation_runs_actor_kind_check;
  end if;
  if exists (select 1 from pg_constraint where conrelid='public.subscription_reconciliation_runs'::regclass and conname='subscription_reconciliation_runs_actor_identity_check') then
    alter table public.subscription_reconciliation_runs drop constraint subscription_reconciliation_runs_actor_identity_check;
  end if;
  if exists (select 1 from pg_constraint where conrelid='public.subscription_reconciliation_audit'::regclass and conname='subscription_reconciliation_audit_actor_kind_check') then
    alter table public.subscription_reconciliation_audit drop constraint subscription_reconciliation_audit_actor_kind_check;
  end if;
  if exists (select 1 from pg_constraint where conrelid='public.subscription_reconciliation_audit'::regclass and conname='subscription_reconciliation_audit_actor_identity_check') then
    alter table public.subscription_reconciliation_audit drop constraint subscription_reconciliation_audit_actor_identity_check;
  end if;
  if exists (select 1 from pg_constraint where conrelid='public.organization_subscription_commercial_audit'::regclass and conname='organization_subscription_commercial_audit_actor_kind_check') then
    alter table public.organization_subscription_commercial_audit drop constraint organization_subscription_commercial_audit_actor_kind_check;
  end if;
  if exists (select 1 from pg_constraint where conrelid='public.organization_subscription_commercial_audit'::regclass and conname='organization_subscription_commercial_audit_actor_identity_check') then
    alter table public.organization_subscription_commercial_audit drop constraint organization_subscription_commercial_audit_actor_identity_check;
  end if;
end
$$;

alter table public.subscription_reconciliation_runs
  add constraint subscription_reconciliation_runs_mode_check check (mode in ('manual','scheduled')),
  add constraint subscription_reconciliation_runs_actor_kind_check check (actor_kind in ('user','system')),
  add constraint subscription_reconciliation_runs_actor_identity_check check ((actor_kind='user' and started_by is not null) or (actor_kind='system' and started_by is null));

alter table public.subscription_reconciliation_audit
  add constraint subscription_reconciliation_audit_actor_kind_check check (actor_kind in ('user','system')),
  add constraint subscription_reconciliation_audit_actor_identity_check check ((actor_kind='user' and reconciled_by is not null) or (actor_kind='system' and reconciled_by is null));

alter table public.organization_subscription_commercial_audit
  add constraint organization_subscription_commercial_audit_actor_kind_check check (actor_kind in ('user','system')),
  add constraint organization_subscription_commercial_audit_actor_identity_check check ((actor_kind='user' and changed_by is not null) or (actor_kind='system' and changed_by is null));

create or replace function public.execute_subscription_expiry_reconciliation_system(as_of timestamptz default statement_timestamp())
returns table(run_id uuid, changed_count integer, skipped_count integer)
language plpgsql
security definer
set search_path=pg_catalog
as $$
declare
  r uuid;
  x record;
  changed integer:=0;
  skipped integer:=0;
  target text;
  act text;
  why text;
begin
  -- Avoid overlapping scheduled executions. Row locks and status predicates also
  -- keep this safe if a superadmin runs the manual reconciler at the same time.
  if not pg_try_advisory_xact_lock(hashtext('subscription_expiry_reconciliation')) then
    return query select null::uuid,0,0;
    return;
  end if;

  if as_of is null or as_of>statement_timestamp()+interval '5 minutes' then
    raise exception using errcode='22023',message='La fecha de reconciliación programada no es válida.';
  end if;

  insert into public.subscription_reconciliation_runs(as_of,mode,started_by,actor_kind)
  values(as_of,'scheduled',null,'system') returning id into r;

  for x in
    select s.id,s.organization_id,s.status,s.renewal_type,s.expires_at
    from public.organization_subscriptions s
    where s.expires_at is not null and s.expires_at<=as_of and s.status in ('trial','active')
    order by s.id
    for update
  loop
    target:=null; act:=null; why:=null;

    if x.status='trial' then
      target:='expired'; act:='expire_trial'; why:='El periodo de prueba alcanzó su fecha de vencimiento.';
    elsif x.status='active' and x.renewal_type in ('manual','none') then
      target:='past_due'; act:='mark_past_due'; why:='La suscripción activa alcanzó su vencimiento sin renovación automática confirmada.';
    else
      skipped:=skipped+1;
      continue;
    end if;

    update public.organization_subscriptions
      set status=target,updated_at=statement_timestamp()
      where id=x.id and status=x.status;

    if found then
      changed:=changed+1;

      insert into public.subscription_reconciliation_audit(
        run_id,subscription_id,organization_id,old_status,new_status,action,reason,reconciled_by,actor_kind
      ) values(r,x.id,x.organization_id,x.status,target,act,why,null,'system');

      insert into public.organization_subscription_commercial_audit(
        organization_id,subscription_id,old_plan_id,new_plan_id,old_status,new_status,change_reason,changed_at,changed_by,actor_kind
      )
      select x.organization_id,x.id,s.plan_id,s.plan_id,x.status,target,
             'Reconciliación automática de vencimiento: '||why,
             statement_timestamp(),null,'system'
      from public.organization_subscriptions s where s.id=x.id;
    else
      skipped:=skipped+1;
    end if;
  end loop;

  update public.subscription_reconciliation_runs
    set changed_count=changed,skipped_count=skipped
    where id=r;

  return query select r,changed,skipped;
end;
$$;

revoke all on function public.execute_subscription_expiry_reconciliation_system(timestamptz) from public,anon,authenticated;

do $$
declare existing_job bigint;
begin
  select jobid into existing_job from cron.job where jobname='subscription-expiry-reconciliation-hourly' limit 1;
  if existing_job is not null then perform cron.unschedule(existing_job); end if;
end
$$;

select cron.schedule(
  'subscription-expiry-reconciliation-hourly',
  '17 * * * *',
  $$select public.execute_subscription_expiry_reconciliation_system(statement_timestamp());$$
);
