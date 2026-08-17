-- Snapshot del estado efectivo de prospectos, eventos y métricas.
-- Requiere la Fase 3A del núcleo de organizaciones y tarjetas.
-- No duplica private.get_effective_plan(uuid), digital_cards,
-- organizations, organization_members, organization_subscriptions ni plans.

begin;

do $preconditions$
begin
  if to_regclass('public.digital_cards') is null
     or to_regclass('public.organizations') is null
     or to_regclass('public.organization_members') is null
     or to_regclass('public.organization_subscriptions') is null
     or to_regclass('public.plans') is null then
    raise exception 'Falta el núcleo organizacional versionado en la Fase 3A.';
  end if;

  if to_regprocedure('private.get_effective_plan(uuid)') is null then
    raise exception 'Falta private.get_effective_plan(uuid) de la Fase 3A.';
  end if;
end;
$preconditions$;

create table public."card_events" (
  "id" uuid default gen_random_uuid() not null,
  "card_id" uuid not null,
  "event_type" text not null,
  "created_at" timestamp with time zone default now(),
  "metadata" jsonb default '{}'::jsonb not null,
  constraint "card_events_card_id_fkey" FOREIGN KEY (card_id) REFERENCES digital_cards(id) ON DELETE CASCADE,
  constraint "card_events_event_type_check" CHECK (event_type = ANY (ARRAY['view'::text, 'whatsapp_click'::text, 'call_click'::text, 'email_click'::text, 'website_click'::text, 'lead_created'::text])),
  constraint "card_events_pkey" PRIMARY KEY (id)
);

create table public."prospects" (
  "id" uuid default gen_random_uuid() not null,
  "card_id" uuid not null,
  "name" text not null,
  "whatsapp" text not null,
  "email" text,
  "created_at" timestamp with time zone default now(),
  "source" text default 'public_card'::text not null,
  "consent_given" boolean default false not null,
  "consent_at" timestamp with time zone,
  "consent_version" text,
  constraint "prospects_card_id_fkey" FOREIGN KEY (card_id) REFERENCES digital_cards(id) ON DELETE CASCADE,
  constraint "prospects_consent_check" CHECK (consent_given = false AND consent_at IS NULL OR consent_given = true AND consent_at IS NOT NULL AND NULLIF(TRIM(BOTH FROM consent_version), ''::text) IS NOT NULL),
  constraint "prospects_pkey" PRIMARY KEY (id)
);

CREATE OR REPLACE FUNCTION private.lock_lead_capture_plan(target_organization_id uuid)
 RETURNS TABLE(subscription_id uuid, subscription_status text, plan_id uuid)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  locked_organization_status text;
  locked_subscription_id uuid;
  locked_subscription_status text;
  locked_subscription_starts_at timestamptz;
  locked_subscription_expires_at timestamptz;
  locked_plan_id uuid;
  locked_plan_status text;
  locked_lead_capture_enabled boolean;
begin
  if target_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'La organización no es válida.';
  end if;

  select organization.status
  into locked_organization_status
  from public.organizations as organization
  where organization.id = target_organization_id
  for update;

  if not found
    or locked_organization_status <> 'active'
  then
    raise exception using
      errcode = 'P0001',
      message = 'La organización no está activa.';
  end if;

  select
    subscription.id,
    subscription.status,
    subscription.starts_at,
    subscription.expires_at,
    subscription.plan_id
  into
    locked_subscription_id,
    locked_subscription_status,
    locked_subscription_starts_at,
    locked_subscription_expires_at,
    locked_plan_id
  from public.organization_subscriptions as subscription
  where subscription.organization_id =
    target_organization_id
    and subscription.status in (
      'trial',
      'active',
      'past_due'
    )
  order by
    subscription.starts_at desc,
    subscription.created_at desc,
    subscription.id desc
  limit 1
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message =
        'La organización no tiene una suscripción utilizable.';
  end if;

  if locked_subscription_status not in (
    'trial',
    'active'
  ) then
    raise exception using
      errcode = 'P0001',
      message =
        'La captura no está disponible con el estado actual de la suscripción.';
  end if;

  if locked_subscription_starts_at > now() then
    raise exception using
      errcode = 'P0001',
      message = 'La suscripción todavía no está vigente.';
  end if;

  if locked_subscription_expires_at is not null
    and locked_subscription_expires_at <= now()
  then
    raise exception using
      errcode = 'P0001',
      message = 'La suscripción ha vencido.';
  end if;

  select
    plan.status,
    plan.lead_capture_enabled
  into
    locked_plan_status,
    locked_lead_capture_enabled
  from public.plans as plan
  where plan.id = locked_plan_id
  for update;

  if not found
    or locked_plan_status <> 'active'
  then
    raise exception using
      errcode = 'P0001',
      message = 'El plan no está activo.';
  end if;

  if locked_lead_capture_enabled is distinct from true then
    raise exception using
      errcode = 'P0001',
      message =
        'El plan no incluye captura de prospectos.';
  end if;

  return query
  select
    locked_subscription_id,
    locked_subscription_status,
    locked_plan_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.record_lead_created_event()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
begin
  insert into public.card_events (card_id, event_type, metadata)
  values (
    new.card_id,
    'lead_created',
    jsonb_build_object(
      'source', coalesce(nullif(btrim(new.source), ''), 'public_card')
    )
  );

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.create_public_prospect(target_card_id uuid, prospect_name text, prospect_phone text, prospect_email text DEFAULT NULL::text, prospect_source text DEFAULT 'public_card'::text, consent_given boolean DEFAULT false)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  normalized_name text;
  normalized_phone text;
  normalized_email text;
  normalized_source text;
  initial_organization_id uuid;
  locked_card record;
  locked_commercial_context record;
  inserted_prospect_id uuid;
begin
  normalized_name := btrim(coalesce(prospect_name, ''));
  normalized_phone := btrim(coalesce(prospect_phone, ''));
  normalized_email := nullif(
    btrim(coalesce(prospect_email, '')),
    ''
  );
  normalized_source := lower(
    btrim(coalesce(prospect_source, ''))
  );

  if target_card_id is null then
    raise exception using
      errcode = '22023',
      message = 'La tarjeta no es válida.';
  end if;

  if normalized_name = ''
    or char_length(normalized_name) > 120
    or normalized_name ~ '[[:cntrl:]]'
  then
    raise exception using
      errcode = '22023',
      message =
        'El nombre es obligatorio y debe tener máximo 120 caracteres.';
  end if;

  if char_length(normalized_phone) < 7
    or char_length(normalized_phone) > 40
    or normalized_phone !~ '^[0-9+(). -]+$'
  then
    raise exception using
      errcode = '22023',
      message = 'El teléfono no es válido.';
  end if;

  if normalized_email is not null
    and (
      char_length(normalized_email) > 254
      or normalized_email !~
        '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
    )
  then
    raise exception using
      errcode = '22023',
      message = 'El correo no es válido.';
  end if;

  if normalized_source not in (
    'public_card',
    'qr'
  ) then
    raise exception using
      errcode = '22023',
      message = 'La fuente no es válida.';
  end if;

  if consent_given is distinct from true then
    raise exception using
      errcode = '22023',
      message = 'El consentimiento explícito es obligatorio.';
  end if;

  select card.organization_id
  into initial_organization_id
  from public.digital_cards as card
  where card.id = target_card_id;

  if not found
    or initial_organization_id is null
  then
    raise exception using
      errcode = 'P0001',
      message = 'La captura no está disponible.';
  end if;

  select commercial_context.*
  into locked_commercial_context
  from private.lock_lead_capture_plan(
    initial_organization_id
  ) as commercial_context;

  select
    card.id,
    card.organization_id,
    card.status,
    card.capture_enabled
  into locked_card
  from public.digital_cards as card
  where card.id = target_card_id
    and card.organization_id =
      initial_organization_id
  for share;

  if not found
    or locked_card.status <> 'published'
    or locked_card.capture_enabled is distinct from true
  then
    raise exception using
      errcode = 'P0001',
      message = 'La captura no está disponible.';
  end if;

  insert into public.prospects (
    card_id,
    name,
    whatsapp,
    email,
    source,
    consent_given,
    consent_at,
    consent_version
  )
  values (
    target_card_id,
    normalized_name,
    normalized_phone,
    normalized_email,
    normalized_source,
    true,
    now(),
    'v1'
  )
  returning id into inserted_prospect_id;

  return inserted_prospect_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.get_organization_metrics(target_organization_id uuid, target_card_id uuid DEFAULT NULL::uuid, requested_days integer DEFAULT NULL::integer)
 RETURNS TABLE(period_start timestamp with time zone, period_end timestamp with time zone, applied_days integer, views bigint, whatsapp_clicks bigint, calls bigint, emails bigint, website_clicks bigint, leads bigint, conversion_rate numeric)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  effective_plan record;
  calculated_start timestamptz;
  calculated_end timestamptz := now();
  calculated_days integer;
  metric_views bigint;
  metric_whatsapp bigint;
  metric_calls bigint;
  metric_emails bigint;
  metric_web bigint;
  metric_leads bigint;
begin
  if (select auth.uid()) is null then
    raise exception using
      errcode = '42501',
      message = 'Se requiere autenticación.';
  end if;

  if target_organization_id is null
    or not exists (
      select 1
      from public.organization_members as member
      where member.organization_id =
        target_organization_id
        and member.user_id = (select auth.uid())
        and member.status = 'active'
    )
  then
    raise exception using
      errcode = '42501',
      message = 'No tienes acceso a esta organización.';
  end if;

  select plan_row.*
  into effective_plan
  from private.get_effective_plan(
    target_organization_id
  ) as plan_row;

  if not found then
    raise exception using
      errcode = 'P0001',
      message =
        'La organización no tiene una suscripción utilizable.';
  end if;

  if effective_plan.analytics_enabled
    is distinct from true
  then
    raise exception using
      errcode = '42501',
      message = 'El plan no incluye estadísticas.';
  end if;

  if requested_days is not null
    and requested_days <= 0
  then
    raise exception using
      errcode = '22023',
      message = 'El periodo solicitado no es válido.';
  end if;

  if effective_plan.analytics_history_days is null then
    calculated_days := requested_days;
  elsif requested_days is null then
    calculated_days :=
      effective_plan.analytics_history_days;
  else
    calculated_days := least(
      requested_days,
      effective_plan.analytics_history_days
    );
  end if;

  if calculated_days is not null then
    calculated_start :=
      calculated_end
      - make_interval(days => calculated_days);
  else
    calculated_start := null;
  end if;

  if target_card_id is not null
    and not exists (
      select 1
      from public.digital_cards as card
      where card.id = target_card_id
        and card.organization_id =
          target_organization_id
    )
  then
    raise exception using
      errcode = '22023',
      message =
        'La tarjeta no pertenece a la organización.';
  end if;

  select
    count(*) filter (
      where event.event_type = 'view'
    ),
    count(*) filter (
      where event.event_type = 'whatsapp_click'
    ),
    count(*) filter (
      where event.event_type = 'call_click'
    ),
    count(*) filter (
      where event.event_type = 'email_click'
    ),
    count(*) filter (
      where event.event_type = 'website_click'
    ),
    count(*) filter (
      where event.event_type = 'lead_created'
    )
  into
    metric_views,
    metric_whatsapp,
    metric_calls,
    metric_emails,
    metric_web,
    metric_leads
  from public.card_events as event
  join public.digital_cards as card
    on card.id = event.card_id
  where card.organization_id =
    target_organization_id
    and (
      target_card_id is null
      or card.id = target_card_id
    )
    and (
      calculated_start is null
      or event.created_at >= calculated_start
    )
    and event.created_at <= calculated_end;

  return query
  select
    calculated_start,
    calculated_end,
    calculated_days,
    coalesce(metric_views, 0),
    coalesce(metric_whatsapp, 0),
    coalesce(metric_calls, 0),
    coalesce(metric_emails, 0),
    coalesce(metric_web, 0),
    coalesce(metric_leads, 0),
    case
      when coalesce(metric_views, 0) = 0 then 0::numeric
      else round(
        metric_leads::numeric
        / metric_views::numeric
        * 100,
        2
      )
    end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_organization_prospects(target_organization_id uuid, target_card_id uuid DEFAULT NULL::uuid, requested_page integer DEFAULT 1, requested_page_size integer DEFAULT 50, sort_direction text DEFAULT 'desc'::text)
 RETURNS TABLE(items jsonb, total_count bigint, page_number integer, page_size integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  effective_plan record;
  normalized_sort text;
  safe_page integer;
  safe_page_size integer;
  row_offset integer;
  matching_count bigint;
  result_items jsonb;
begin
  if (select auth.uid()) is null then
    raise exception using
      errcode = '42501',
      message = 'Se requiere autenticación.';
  end if;

  if target_organization_id is null
    or not exists (
      select 1
      from public.organization_members as member
      where member.organization_id =
        target_organization_id
        and member.user_id = (select auth.uid())
        and member.status = 'active'
        and member.role in (
          'owner',
          'admin',
          'editor'
        )
    )
  then
    raise exception using
      errcode = '42501',
      message =
        'No tienes permiso para consultar prospectos.';
  end if;

  select plan_row.*
  into effective_plan
  from private.get_effective_plan(
    target_organization_id
  ) as plan_row;

  if not found then
    raise exception using
      errcode = 'P0001',
      message =
        'La organización no tiene una suscripción utilizable.';
  end if;

  if target_card_id is not null
    and not exists (
      select 1
      from public.digital_cards as card
      where card.id = target_card_id
        and card.organization_id =
          target_organization_id
    )
  then
    raise exception using
      errcode = '22023',
      message =
        'La tarjeta no pertenece a la organización.';
  end if;

  safe_page := greatest(coalesce(requested_page, 1), 1);
  safe_page_size := least(
    greatest(coalesce(requested_page_size, 50), 1),
    100
  );

  if safe_page > 100000 then
    raise exception using
      errcode = '22023',
      message = 'La página solicitada no es válida.';
  end if;

  normalized_sort := lower(
    btrim(coalesce(sort_direction, 'desc'))
  );

  if normalized_sort not in ('asc', 'desc') then
    raise exception using
      errcode = '22023',
      message = 'El orden solicitado no es válido.';
  end if;

  row_offset := (safe_page - 1) * safe_page_size;

  select count(*)
  into matching_count
  from public.prospects as prospect
  join public.digital_cards as card
    on card.id = prospect.card_id
  where card.organization_id =
    target_organization_id
    and (
      target_card_id is null
      or card.id = target_card_id
    );

  if normalized_sort = 'asc' then
    select coalesce(
      jsonb_agg(
        page_row.item
        order by
          page_row.created_at asc,
          page_row.prospect_id asc
      ),
      '[]'::jsonb
    )
    into result_items
    from (
      select
        prospect.created_at,
        prospect.id as prospect_id,
        jsonb_build_object(
          'id', prospect.id,
          'card_id', prospect.card_id,
          'name', prospect.name,
          'phone', prospect.whatsapp,
          'email', prospect.email,
          'card_name', card.name,
          'created_at', prospect.created_at,
          'source', prospect.source,
          'consent_given', prospect.consent_given,
          'consent_at', prospect.consent_at,
          'consent_version', prospect.consent_version
        ) as item
      from public.prospects as prospect
      join public.digital_cards as card
        on card.id = prospect.card_id
      where card.organization_id =
        target_organization_id
        and (
          target_card_id is null
          or card.id = target_card_id
        )
      order by
        prospect.created_at asc,
        prospect.id asc
      limit safe_page_size
      offset row_offset
    ) as page_row;
  else
    select coalesce(
      jsonb_agg(
        page_row.item
        order by
          page_row.created_at desc,
          page_row.prospect_id desc
      ),
      '[]'::jsonb
    )
    into result_items
    from (
      select
        prospect.created_at,
        prospect.id as prospect_id,
        jsonb_build_object(
          'id', prospect.id,
          'card_id', prospect.card_id,
          'name', prospect.name,
          'phone', prospect.whatsapp,
          'email', prospect.email,
          'card_name', card.name,
          'created_at', prospect.created_at,
          'source', prospect.source,
          'consent_given', prospect.consent_given,
          'consent_at', prospect.consent_at,
          'consent_version', prospect.consent_version
        ) as item
      from public.prospects as prospect
      join public.digital_cards as card
        on card.id = prospect.card_id
      where card.organization_id =
        target_organization_id
        and (
          target_card_id is null
          or card.id = target_card_id
        )
      order by
        prospect.created_at desc,
        prospect.id desc
      limit safe_page_size
      offset row_offset
    ) as page_row;
  end if;

  return query
  select
    result_items,
    matching_count,
    safe_page,
    safe_page_size;
end;
$function$;

CREATE INDEX card_events_card_created_type_idx ON public.card_events USING btree (card_id, created_at DESC, event_type);

CREATE INDEX card_events_card_id_created_at_idx ON public.card_events USING btree (card_id, created_at DESC);

CREATE INDEX prospects_card_id_created_at_idx ON public.prospects USING btree (card_id, created_at DESC);

CREATE INDEX prospects_created_at_id_idx ON public.prospects USING btree (created_at DESC, id DESC, card_id);

CREATE TRIGGER prospects_record_lead_created_event AFTER INSERT ON prospects FOR EACH ROW EXECUTE FUNCTION record_lead_created_event();

alter table public."card_events" enable row level security;
alter table public."prospects" enable row level security;

create policy "Owners delete prospects"
on public."prospects"
as permissive
for delete
to "authenticated"
using ((EXISTS ( SELECT 1
   FROM digital_cards c
  WHERE ((c.id = prospects.card_id) AND (c.owner_id = ( SELECT auth.uid() AS uid))))))
;

-- ACL efectivas de tabla: navegador sin acceso directo.
revoke all privileges
on table public.prospects, public.card_events
from public, anon, authenticated, service_role;

grant insert, references, trigger, truncate, maintain
on table public.prospects, public.card_events
to service_role;

-- ACL exactas de funciones.
revoke all on function private.lock_lead_capture_plan(uuid)
from public, anon, authenticated, service_role;

revoke all on function public.record_lead_created_event()
from public, anon, authenticated, service_role;

revoke all on function public.create_public_prospect(
  uuid, text, text, text, text, boolean
)
from public, anon, authenticated, service_role;

grant execute on function public.create_public_prospect(
  uuid, text, text, text, text, boolean
)
to service_role;

revoke all on function public.get_organization_metrics(uuid, uuid, integer)
from public, anon, authenticated, service_role;

grant execute on function public.get_organization_metrics(uuid, uuid, integer)
to authenticated;

revoke all on function public.list_organization_prospects(
  uuid, uuid, integer, integer, text
)
from public, anon, authenticated, service_role;

grant execute on function public.list_organization_prospects(
  uuid, uuid, integer, integer, text
)
to authenticated;

commit;
