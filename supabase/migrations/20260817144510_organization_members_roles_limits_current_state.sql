-- Snapshot del estado efectivo del flujo de miembros, roles y límites.
--
-- Precondiciones versionadas en 3A y deliberadamente no duplicadas aquí:
--   public.organizations
--   public.organization_members (columnas, constraints, índices y RLS)
--   public.organization_subscriptions
--   public.plans (incluido max_members)
--   private.get_effective_plan(uuid)
--   private.is_organization_member(uuid)
--   private.set_updated_at()
--   private.ensure_organization_has_active_owner()
--   triggers organization_members_set_updated_at y
--            organization_members_require_active_owner
--   policy "Members read organization memberships"
--   grants efectivos de public.organization_members

begin;

do $preconditions$
begin
  if to_regclass('public.organizations') is null
     or to_regclass('public.organization_members') is null
     or to_regclass('public.organization_subscriptions') is null
     or to_regclass('public.plans') is null
  then
    raise exception
      'Fase 3D requiere las tablas del núcleo organizacional versionadas en 3A.';
  end if;

  if to_regprocedure('private.get_effective_plan(uuid)') is null
     or to_regprocedure('private.is_organization_member(uuid)') is null
     or to_regprocedure('private.set_updated_at()') is null
     or to_regprocedure('private.ensure_organization_has_active_owner()') is null
  then
    raise exception
      'Fase 3D requiere los helpers organizacionales versionados en 3A.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_definition
    where constraint_definition.conrelid =
          'public.organization_members'::regclass
      and constraint_definition.conname = 'organization_members_pkey'
      and constraint_definition.contype = 'p'
  )
  or not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_definition
    where constraint_definition.conrelid =
          'public.organization_members'::regclass
      and constraint_definition.conname = 'organization_members_role_check'
      and constraint_definition.contype = 'c'
  )
  or not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_definition
    where constraint_definition.conrelid =
          'public.organization_members'::regclass
      and constraint_definition.conname = 'organization_members_status_check'
      and constraint_definition.contype = 'c'
  )
  or not exists (
    select 1
    from pg_catalog.pg_constraint as constraint_definition
    where constraint_definition.conrelid =
          'public.organization_members'::regclass
      and constraint_definition.conname =
          'organization_members_timestamps_check'
      and constraint_definition.contype = 'c'
  )
  then
    raise exception
      'Fase 3D requiere los constraints de organization_members versionados en 3A.';
  end if;

  if to_regclass('public.organization_members_active_org_idx') is null
     or to_regclass('public.organization_members_active_user_idx') is null
     or to_regclass('public.organization_members_user_id_idx') is null
  then
    raise exception
      'Fase 3D requiere los índices de organization_members versionados en 3A.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_trigger as trigger_definition
    where trigger_definition.tgrelid = 'public.organization_members'::regclass
      and trigger_definition.tgname =
          'organization_members_require_active_owner'
      and not trigger_definition.tgisinternal
  )
  or not exists (
    select 1
    from pg_catalog.pg_trigger as trigger_definition
    where trigger_definition.tgrelid = 'public.organization_members'::regclass
      and trigger_definition.tgname = 'organization_members_set_updated_at'
      and not trigger_definition.tgisinternal
  )
  then
    raise exception
      'Fase 3D requiere los triggers de organization_members versionados en 3A.';
  end if;

  if not exists (
    select 1
    from pg_catalog.pg_policies as policy_definition
    where policy_definition.schemaname = 'public'
      and policy_definition.tablename = 'organization_members'
      and policy_definition.policyname =
          'Members read organization memberships'
      and policy_definition.cmd = 'SELECT'
  )
  then
    raise exception
      'Fase 3D requiere la policy de lectura de organization_members versionada en 3A.';
  end if;
end;
$preconditions$;

CREATE OR REPLACE FUNCTION private.lock_member_plan_context(target_organization_id uuid, require_expansion boolean)
 RETURNS TABLE(commercial_status text, max_members integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  initial_effective_plan record;
  locked_organization_status text;
  locked_subscription record;
  locked_plan record;
  diagnostic_subscription record;
  active_member_count bigint;
  resolved_status text;
  resolved_max_members integer;
begin
  if target_organization_id is null then
    raise exception using
      errcode = '22023',
      message = 'La organización es obligatoria.';
  end if;

  /*
   * La lectura es no bloqueante. Solo identifica los IDs definidos por
   * private.get_effective_plan(); no toma una decisión comercial final.
   */
  if coalesce(require_expansion, false) then
    select *
      into initial_effective_plan
    from private.get_effective_plan(target_organization_id);
  end if;

  /*
   * Orden global:
   * organización → suscripción → plan → membresía.
   */
  select organization.status
    into locked_organization_status
  from public.organizations as organization
  where organization.id = target_organization_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'La organización no existe.';
  end if;

  if locked_organization_status <> 'active' then
    raise exception using
      errcode = '42501',
      message = 'La organización no está activa.';
  end if;

  if coalesce(require_expansion, false) then
    if initial_effective_plan.subscription_id is null
       or initial_effective_plan.plan_id is null
    then
      raise exception using
        errcode = '42501',
        message =
          'La suscripción actual no permite agregar o reactivar miembros.';
    end if;

    /*
     * Se bloquea exactamente la suscripción identificada por
     * private.get_effective_plan().
     */
    select
      subscription.id,
      subscription.organization_id,
      subscription.plan_id,
      subscription.status,
      subscription.starts_at,
      subscription.expires_at
    into locked_subscription
    from public.organization_subscriptions as subscription
    where subscription.id = initial_effective_plan.subscription_id
      and subscription.organization_id = target_organization_id
    for update;

    if not found
       or locked_subscription.plan_id
          is distinct from initial_effective_plan.plan_id
       or locked_subscription.status not in ('trial', 'active')
       or locked_subscription.starts_at > now()
       or (
         locked_subscription.expires_at is not null
         and locked_subscription.expires_at <= now()
       )
    then
      raise exception using
        errcode = '42501',
        message =
          'La suscripción actual no permite agregar o reactivar miembros.';
    end if;

    select
      plan.id,
      plan.status,
      plan.max_members
    into locked_plan
    from public.plans as plan
    where plan.id = initial_effective_plan.plan_id
    for share;

    if not found
       or locked_plan.status <> 'active'
       or locked_plan.max_members is null
       or locked_plan.max_members <= 0
    then
      raise exception using
        errcode = '42501',
        message =
          'La suscripción actual no permite agregar o reactivar miembros.';
    end if;

    /*
     * Revalidación adicional: el contexto efectivo sigue apuntando a
     * las mismas filas que fueron bloqueadas.
     */
    if not exists (
      select 1
      from private.get_effective_plan(target_organization_id)
        as effective
      where effective.subscription_id = locked_subscription.id
        and effective.plan_id = locked_plan.id
        and effective.subscription_status in ('trial', 'active')
    ) then
      raise exception using
        errcode = '40001',
        message =
          'La suscripción cambió durante la operación. Intenta nuevamente.';
    end if;

    select count(*)
      into active_member_count
    from public.organization_members as member
    where member.organization_id = target_organization_id
      and member.status = 'active';

    if active_member_count >= locked_plan.max_members then
      raise exception using
        errcode = 'P0001',
        message = 'Has alcanzado el límite de miembros de tu plan.';
    end if;

    resolved_status := locked_subscription.status;
    resolved_max_members := locked_plan.max_members;
  else
    /*
     * Las reducciones no requieren plan efectivo. Primero se intenta
     * identificar el contexto efectivo canónico.
     */
    select *
      into initial_effective_plan
    from private.get_effective_plan(target_organization_id);

    if initial_effective_plan.subscription_id is not null
       and initial_effective_plan.plan_id is not null
    then
      select
        subscription.id,
        subscription.organization_id,
        subscription.plan_id,
        subscription.status,
        subscription.starts_at,
        subscription.expires_at
      into locked_subscription
      from public.organization_subscriptions as subscription
      where subscription.id = initial_effective_plan.subscription_id
        and subscription.organization_id = target_organization_id
      for update;

      if found then
        select
          plan.id,
          plan.status,
          plan.max_members
        into locked_plan
        from public.plans as plan
        where plan.id = locked_subscription.plan_id
        for share;
      end if;

      if locked_subscription.id is not null
         and locked_plan.id is not null
         and locked_plan.status = 'active'
         and locked_subscription.status
             in ('trial', 'active', 'past_due')
         and locked_subscription.starts_at <= now()
         and (
           locked_subscription.expires_at is null
           or locked_subscription.expires_at > now()
         )
      then
        resolved_status := locked_subscription.status;
        resolved_max_members := locked_plan.max_members;
      end if;
    end if;

    /*
     * Esta selección solo clasifica un estado no efectivo para UI y
     * reglas reductoras. Nunca concede capacidad ni max_members.
     */
    if resolved_status is null then
      select
        subscription.id,
        subscription.plan_id,
        subscription.status,
        subscription.starts_at,
        subscription.expires_at
      into diagnostic_subscription
      from public.organization_subscriptions as subscription
      where subscription.organization_id = target_organization_id
      order by
        subscription.starts_at desc,
        subscription.created_at desc,
        subscription.id desc
      limit 1
      for update;

      if not found then
        resolved_status := 'no_subscription';
        resolved_max_members := null;
      else
        select
          plan.id,
          plan.status,
          plan.max_members
        into locked_plan
        from public.plans as plan
        where plan.id = diagnostic_subscription.plan_id
        for share;

        resolved_max_members := null;

        if locked_plan.id is null
           or locked_plan.status <> 'active'
        then
          resolved_status := 'plan_inactive';
        elsif diagnostic_subscription.status = 'cancelled' then
          resolved_status := 'cancelled';
        elsif diagnostic_subscription.status = 'expired'
           or (
             diagnostic_subscription.expires_at is not null
             and diagnostic_subscription.expires_at <= now()
           )
        then
          resolved_status := 'expired';
        elsif diagnostic_subscription.starts_at > now() then
          resolved_status := 'not_started';
        elsif diagnostic_subscription.status = 'past_due' then
          resolved_status := 'past_due';
        else
          /*
           * Si aparentemente debería ser efectiva pero el helper canónico
           * no la seleccionó, no se concede capacidad.
           */
          resolved_status := 'no_subscription';
        end if;
      end if;
    end if;
  end if;

  return query
  select resolved_status, resolved_max_members;
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_organization_members(target_organization_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  caller_role text;
  effective_plan record;
  diagnostic_subscription record;
  diagnostic_plan record;
  active_count bigint;
  members_json jsonb;
  resolved_status text;
  resolved_max_members integer;
begin
  current_user_id := auth.uid();

  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  select member.role
    into caller_role
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = current_user_id
    and member.status = 'active';

  if not found then
    raise exception using
      errcode = '42501',
      message = 'No tienes acceso a esta organización.';
  end if;

  select *
    into effective_plan
  from private.get_effective_plan(target_organization_id);

  if effective_plan.subscription_id is not null then
    resolved_status := effective_plan.subscription_status;
    resolved_max_members := effective_plan.max_members;
  else
    /*
     * Diagnóstico explícito de una suscripción no efectiva.
     * max_members permanece NULL porque no representa capacidad vigente.
     */
    select
      subscription.id,
      subscription.plan_id,
      subscription.status,
      subscription.starts_at,
      subscription.expires_at
    into diagnostic_subscription
    from public.organization_subscriptions as subscription
    where subscription.organization_id = target_organization_id
    order by
      subscription.starts_at desc,
      subscription.created_at desc,
      subscription.id desc
    limit 1;

    resolved_max_members := null;

    if not found then
      resolved_status := 'no_subscription';
    else
      select
        plan.id,
        plan.status
      into diagnostic_plan
      from public.plans as plan
      where plan.id = diagnostic_subscription.plan_id;

      if diagnostic_plan.id is null
         or diagnostic_plan.status <> 'active'
      then
        resolved_status := 'plan_inactive';
      elsif diagnostic_subscription.status = 'cancelled' then
        resolved_status := 'cancelled';
      elsif diagnostic_subscription.status = 'expired'
         or (
           diagnostic_subscription.expires_at is not null
           and diagnostic_subscription.expires_at <= now()
         )
      then
        resolved_status := 'expired';
      elsif diagnostic_subscription.starts_at > now() then
        resolved_status := 'not_started';
      elsif diagnostic_subscription.status = 'past_due' then
        resolved_status := 'past_due';
      else
        resolved_status := 'no_subscription';
      end if;
    end if;
  end if;

  select count(*)
    into active_count
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.status = 'active';

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'user_id',
          case
            when caller_role in ('owner', 'admin')
              or member.user_id = current_user_id
            then to_jsonb(member.user_id)
            else 'null'::jsonb
          end,
        'email',
          case
            when caller_role in ('owner', 'admin')
            then to_jsonb(auth_user.email)
            else 'null'::jsonb
          end,
        'role', member.role,
        'status', member.status,
        'created_at', member.created_at,
        'updated_at', member.updated_at,
        'is_current_user', member.user_id = current_user_id
      )
      order by
        case member.role
          when 'owner' then 1
          when 'admin' then 2
          when 'editor' then 3
          when 'viewer' then 4
        end,
        member.created_at,
        member.user_id
    ),
    '[]'::jsonb
  )
  into members_json
  from public.organization_members as member
  join auth.users as auth_user
    on auth_user.id = member.user_id
  where member.organization_id = target_organization_id;

  return jsonb_build_object(
    'items', members_json,
    'active_count', active_count,
    'max_members', resolved_max_members,
    'effective_subscription_status',
      coalesce(resolved_status, 'no_subscription'),
    'caller_role', caller_role,
    'can_manage', caller_role in ('owner', 'admin')
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.add_organization_member_by_email(target_organization_id uuid, member_email text, member_role text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  caller_role text;
  normalized_email text;
  normalized_role text;
  target_auth_user_id uuid;
  eligible_user_count bigint;
  existing_member public.organization_members%rowtype;
  inserted_member public.organization_members%rowtype;
begin
  current_user_id := auth.uid();

  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  normalized_email := lower(btrim(coalesce(member_email, '')));
  normalized_role := lower(btrim(coalesce(member_role, '')));

  if normalized_email = ''
     or char_length(normalized_email) > 320
     or normalized_email !~
       '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  then
    raise exception using
      errcode = '22023',
      message = 'La cuenta indicada no existe o no es elegible.';
  end if;

  if normalized_role not in ('owner', 'admin', 'editor', 'viewer') then
    raise exception using
      errcode = '22023',
      message = 'El rol solicitado no es válido.';
  end if;

  select member.role
    into caller_role
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = current_user_id
    and member.status = 'active';

  if caller_role not in ('owner', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'No tienes permiso para administrar miembros.';
  end if;

  if caller_role = 'admin'
     and normalized_role = 'owner'
  then
    raise exception using
      errcode = '42501',
      message = 'Un administrador no puede crear owners.';
  end if;

  perform *
  from private.lock_member_plan_context(
    target_organization_id,
    true
  );

  select
    count(*),
    min(auth_user.id)
  into
    eligible_user_count,
    target_auth_user_id
  from auth.users as auth_user
  where lower(btrim(auth_user.email)) = normalized_email
    and auth_user.deleted_at is null
    and auth_user.is_anonymous is false
    and coalesce(
      auth_user.email_confirmed_at,
      auth_user.confirmed_at
    ) is not null
    and (
      auth_user.banned_until is null
      or auth_user.banned_until <= now()
    );

  if eligible_user_count <> 1
     or target_auth_user_id is null
  then
    raise exception using
      errcode = 'P0001',
      message = 'La cuenta indicada no existe o no es elegible.';
  end if;

  select *
    into existing_member
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_auth_user_id
  for update;

  if found then
    raise exception using
      errcode = '23505',
      message = 'La cuenta indicada no existe o no es elegible.';
  end if;

  insert into public.organization_members (
    organization_id,
    user_id,
    role,
    status,
    created_by
  )
  values (
    target_organization_id,
    target_auth_user_id,
    normalized_role,
    'active',
    current_user_id
  )
  returning *
    into inserted_member;

  return jsonb_build_object(
    'user_id', inserted_member.user_id,
    'role', inserted_member.role,
    'status', inserted_member.status,
    'created_at', inserted_member.created_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.update_organization_member(target_organization_id uuid, target_user_id uuid, new_role text, new_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  caller_role text;
  initial_target_role text;
  initial_target_status text;
  normalized_role text;
  normalized_status text;
  requires_expansion boolean;
  commercial_context record;
  locked_target public.organization_members%rowtype;
  updated_member public.organization_members%rowtype;
  other_active_owner_count bigint;
begin
  current_user_id := auth.uid();

  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  if target_organization_id is null
     or target_user_id is null
  then
    raise exception using
      errcode = '22023',
      message = 'La organización y el miembro son obligatorios.';
  end if;

  normalized_role := lower(btrim(coalesce(new_role, '')));
  normalized_status := lower(btrim(coalesce(new_status, '')));

  if normalized_role not in ('owner', 'admin', 'editor', 'viewer')
     or normalized_status not in ('active', 'disabled')
  then
    raise exception using
      errcode = '22023',
      message = 'El rol o estado solicitado no es válido.';
  end if;

  select member.role
    into caller_role
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = current_user_id
    and member.status = 'active';

  if caller_role not in ('owner', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'No tienes permiso para administrar miembros.';
  end if;

  /*
   * Lectura no bloqueante para determinar si la operación aumenta
   * active_count. La fila se revalida después de los locks comerciales.
   */
  select member.role, member.status
    into initial_target_role, initial_target_status
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'El miembro no existe.';
  end if;

  if caller_role = 'admin'
     and (
       target_user_id = current_user_id
       or initial_target_role = 'owner'
       or normalized_role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message = 'Un administrador no puede realizar ese cambio.';
  end if;

  requires_expansion :=
    initial_target_status = 'disabled'
    and normalized_status = 'active';

  select *
    into commercial_context
  from private.lock_member_plan_context(
    target_organization_id,
    requires_expansion
  );

  /*
   * El lock de membership se adquiere después de organización,
   * suscripción y plan.
   */
  select *
    into locked_target
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id
  for update;

  if not found
     or locked_target.role is distinct from initial_target_role
     or locked_target.status is distinct from initial_target_status
  then
    raise exception using
      errcode = '40001',
      message =
        'La membresía cambió durante la operación. Intenta nuevamente.';
  end if;

  /*
   * Cambios de rol que no alteran active_count:
   * trial/active/past_due sí; estados no efectivos no.
   *
   * Deshabilitar sigue siendo una reducción válida en cualquier estado.
   */
  if locked_target.status = 'active'
     and normalized_status = 'active'
     and normalized_role is distinct from locked_target.role
     and commercial_context.commercial_status
         not in ('trial', 'active', 'past_due')
  then
    raise exception using
      errcode = '42501',
      message = 'La suscripción actual no permite cambiar roles.';
  end if;

  if locked_target.role = 'owner'
     and locked_target.status = 'active'
     and (
       normalized_role <> 'owner'
       or normalized_status <> 'active'
     )
  then
    select count(*)
      into other_active_owner_count
    from public.organization_members as member
    where member.organization_id = target_organization_id
      and member.user_id <> target_user_id
      and member.role = 'owner'
      and member.status = 'active';

    if other_active_owner_count = 0 then
      raise exception using
        errcode = '23514',
        message = 'No puedes modificar al último owner activo.';
    end if;
  end if;

  update public.organization_members as member
  set
    role = normalized_role,
    status = normalized_status,
    updated_at = now()
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id
  returning *
    into updated_member;

  return jsonb_build_object(
    'user_id', updated_member.user_id,
    'role', updated_member.role,
    'status', updated_member.status,
    'updated_at', updated_member.updated_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.remove_organization_member(target_organization_id uuid, target_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid;
  caller_role text;
  initial_target_role text;
  initial_target_status text;
  locked_target public.organization_members%rowtype;
  other_active_owner_count bigint;
begin
  current_user_id := auth.uid();

  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  if target_organization_id is null
     or target_user_id is null
  then
    raise exception using
      errcode = '22023',
      message = 'La organización y el miembro son obligatorios.';
  end if;

  select member.role
    into caller_role
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = current_user_id
    and member.status = 'active';

  if caller_role not in ('owner', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'No tienes permiso para administrar miembros.';
  end if;

  select member.role, member.status
    into initial_target_role, initial_target_status
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'El miembro no existe.';
  end if;

  if caller_role = 'admin'
     and (
       target_user_id = current_user_id
       or initial_target_role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message = 'Un administrador no puede eliminar esa membresía.';
  end if;

  /*
   * require_expansion=false permite eliminar aunque no exista
   * suscripción efectiva.
   */
  perform *
  from private.lock_member_plan_context(
    target_organization_id,
    false
  );

  select *
    into locked_target
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id
  for update;

  if not found
     or locked_target.role is distinct from initial_target_role
     or locked_target.status is distinct from initial_target_status
  then
    raise exception using
      errcode = '40001',
      message =
        'La membresía cambió durante la operación. Intenta nuevamente.';
  end if;

  if locked_target.role = 'owner'
     and locked_target.status = 'active'
  then
    select count(*)
      into other_active_owner_count
    from public.organization_members as member
    where member.organization_id = target_organization_id
      and member.user_id <> target_user_id
      and member.role = 'owner'
      and member.status = 'active';

    if other_active_owner_count = 0 then
      raise exception using
        errcode = '23514',
        message = 'No puedes eliminar al último owner activo.';
    end if;
  end if;

  delete from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = target_user_id;

  return jsonb_build_object(
    'removed', true,
    'user_id', target_user_id
  );
end;
$function$;

-- ACL efectivas. La tabla y su RLS pertenecen al snapshot 3A; se
-- reafirman aquí únicamente los grants vigentes del bloque de miembros.
revoke all privileges
on table public.organization_members
from public, anon, authenticated, service_role;

grant select
on table public.organization_members
to authenticated;

grant references, trigger, truncate, maintain
on table public.organization_members
to service_role;

revoke all
on function private.lock_member_plan_context(uuid, boolean)
from public, anon, authenticated, service_role;

revoke all
on function public.list_organization_members(uuid)
from public, anon, authenticated, service_role;

revoke all
on function public.add_organization_member_by_email(uuid, text, text)
from public, anon, authenticated, service_role;

revoke all
on function public.update_organization_member(uuid, uuid, text, text)
from public, anon, authenticated, service_role;

revoke all
on function public.remove_organization_member(uuid, uuid)
from public, anon, authenticated, service_role;

grant execute
on function public.list_organization_members(uuid)
to authenticated;

grant execute
on function public.add_organization_member_by_email(uuid, text, text)
to authenticated;

grant execute
on function public.update_organization_member(uuid, uuid, text, text)
to authenticated;

grant execute
on function public.remove_organization_member(uuid, uuid)
to authenticated;

commit;
