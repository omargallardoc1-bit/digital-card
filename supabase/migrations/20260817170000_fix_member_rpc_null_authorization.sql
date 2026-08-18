begin;

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

  if caller_role is null
     or caller_role not in ('owner', 'admin')
  then
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
    (array_agg(auth_user.id order by auth_user.id))[1]
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

  if caller_role is null
     or caller_role not in ('owner', 'admin')
  then
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

  if caller_role is null
     or caller_role not in ('owner', 'admin')
  then
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

commit;
