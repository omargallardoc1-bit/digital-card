-- Snapshot fiel del backend de invitaciones actualmente desplegado.
-- Esta migración presupone que el núcleo organizacional y de planes ya existe.
-- Dependencias deliberadamente no duplicadas:
--   private.get_effective_plan(uuid)
--   private.lock_member_plan_context(uuid, boolean)
--   private.set_updated_at()
--   public.organizations
--   public.organization_members
--   public.organization_subscriptions
--   public.plans
--   extensions.digest(bytea, text)
--
-- Antes de aplicar este archivo sobre un proyecto que ya contiene estas
-- entidades, hay que coordinar su baseline/historial de migraciones.

begin;

do $preconditions$
begin
  if to_regnamespace('private') is null then
    raise exception 'Falta el esquema private requerido por invitaciones.';
  end if;
  if to_regclass('public.organizations') is null
     or to_regclass('public.organization_members') is null
     or to_regclass('public.organization_subscriptions') is null
     or to_regclass('public.plans') is null then
    raise exception 'Falta el núcleo organizacional requerido por invitaciones.';
  end if;
  if to_regprocedure('private.get_effective_plan(uuid)') is null
     or to_regprocedure('private.lock_member_plan_context(uuid,boolean)') is null
     or to_regprocedure('private.set_updated_at()') is null then
    raise exception 'Faltan helpers previos de plan, miembros o timestamps.';
  end if;
  if to_regprocedure('extensions.digest(bytea,text)') is null then
    raise exception 'Falta extensions.digest(bytea,text) (pgcrypto).';
  end if;
end;
$preconditions$;

create table public.organization_invitations (
  id uuid not null default gen_random_uuid(),
  organization_id uuid not null,
  email text not null,
  role text not null,
  status text not null default 'pending'::text,
  invited_by uuid,
  accepted_by uuid,
  token_hash bytea not null,
  expires_at timestamp with time zone not null,
  accepted_at timestamp with time zone,
  revoked_at timestamp with time zone,
  last_sent_at timestamp with time zone not null default now(),
  send_count integer not null default 1,
  created_at timestamp with time zone not null default now(),
  updated_at timestamp with time zone not null default now(),
  constraint organization_invitations_pkey primary key (id),
  constraint organization_invitations_organization_id_fkey
    foreign key (organization_id)
    references public.organizations(id)
    on delete cascade,
  constraint organization_invitations_invited_by_fkey
    foreign key (invited_by)
    references auth.users(id)
    on delete set null,
  constraint organization_invitations_accepted_by_fkey
    foreign key (accepted_by)
    references auth.users(id)
    on delete set null,
  constraint organization_invitations_email_normalized_check
    check (
      email = lower(btrim(email))
      and char_length(email) >= 3
      and char_length(email) <= 320
      and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'::text
    ),
  constraint organization_invitations_role_check
    check (role = any (array['owner'::text, 'admin'::text, 'editor'::text, 'viewer'::text])),
  constraint organization_invitations_status_check
    check (status = any (array['pending'::text, 'accepted'::text, 'expired'::text, 'revoked'::text])),
  constraint organization_invitations_token_hash_check
    check (octet_length(token_hash) = 32),
  constraint organization_invitations_expiry_check
    check (expires_at > created_at),
  constraint organization_invitations_send_count_check
    check (send_count >= 1 and send_count <= 20),
  constraint organization_invitations_timestamps_check
    check (updated_at >= created_at),
  constraint organization_invitations_state_check
    check (
      (
        status = 'accepted'::text
        and accepted_at is not null
        and revoked_at is null
      )
      or (
        status = 'revoked'::text
        and revoked_at is not null
        and accepted_at is null
        and accepted_by is null
      )
      or (
        status = any (array['pending'::text, 'expired'::text])
        and accepted_at is null
        and accepted_by is null
        and revoked_at is null
      )
    )
);

create index organization_invitations_expiration_idx
  on public.organization_invitations using btree (expires_at)
  where status = 'pending'::text;

create unique index organization_invitations_one_pending_email_idx
  on public.organization_invitations using btree (organization_id, email)
  where status = 'pending'::text;

create index organization_invitations_org_status_created_idx
  on public.organization_invitations using btree (organization_id, status, created_at desc);

create unique index organization_invitations_token_hash_idx
  on public.organization_invitations using btree (token_hash);

create trigger organization_invitations_set_updated_at
before update on public.organization_invitations
for each row
execute function private.set_updated_at();

CREATE OR REPLACE FUNCTION private.invitation_actor_role(target_organization_id uuid, actor_user_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
  select member.role
  from public.organization_members as member
  where member.organization_id = target_organization_id
    and member.user_id = actor_user_id
    and member.status = 'active'
    and member.role in ('owner', 'admin')
  limit 1;
$function$;

CREATE OR REPLACE FUNCTION public.create_organization_invitation(target_organization_id uuid, invitation_email text, invitation_role text, invitation_token_hash bytea, invitation_expires_at timestamp with time zone, actor_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  normalized_email text :=
    lower(btrim(coalesce(invitation_email, '')));

  normalized_role text :=
    lower(btrim(coalesce(invitation_role, '')));

  initial_actor_role text;
  locked_actor_role text;

  existing_invitation
    public.organization_invitations%rowtype;

  inserted_invitation
    public.organization_invitations%rowtype;
begin
  if target_organization_id is null
     or actor_user_id is null
     or normalized_email = ''
     or normalized_role not in (
       'owner', 'admin', 'editor', 'viewer'
     )
     or invitation_token_hash is null
     or octet_length(invitation_token_hash) <> 32
     or invitation_expires_at <= now()
     or invitation_expires_at >
       now() + interval '14 days'
  then
    raise exception using
      errcode = '22023',
      message = 'La solicitud de invitación no es válida.';
  end if;

  initial_actor_role :=
    private.invitation_actor_role(
      target_organization_id,
      actor_user_id
    );

  if initial_actor_role is null
     or (
       initial_actor_role = 'admin'
       and normalized_role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message =
        'No tienes permiso para crear esta invitación.';
  end if;

  perform *
  from private.lock_member_plan_context(
    target_organization_id,
    true
  );

  select invitation.*
  into existing_invitation
  from public.organization_invitations as invitation
  where invitation.organization_id =
      target_organization_id
    and invitation.email = normalized_email
    and invitation.status = 'pending'
  order by invitation.created_at desc
  limit 1
  for update;

  select member.role
  into locked_actor_role
  from public.organization_members as member
  where member.organization_id =
      target_organization_id
    and member.user_id = actor_user_id
    and member.status = 'active'
  for share;

  if locked_actor_role is null
     or locked_actor_role is distinct from
       initial_actor_role
     or (
       locked_actor_role = 'admin'
       and normalized_role = 'owner'
     )
  then
    raise exception using
      errcode = '40001',
      message =
        'Tus permisos cambiaron durante la operación. Intenta nuevamente.';
  end if;

  if existing_invitation.id is not null then
    if existing_invitation.expires_at <= now() then
      update public.organization_invitations as invitation
      set
        status = 'expired',
        updated_at = now()
      where invitation.id = existing_invitation.id;
    else
      raise exception using
        errcode = '23505',
        message =
          'Ya existe una invitación pendiente para ese correo.';
    end if;
  end if;

  if (
    select count(*)
    from public.organization_invitations as invitation
    where invitation.organization_id =
      target_organization_id
      and invitation.created_at >=
        now() - interval '24 hours'
  ) >= 20 then
    raise exception using
      errcode = 'P0001',
      message =
        'Se alcanzó temporalmente el límite de invitaciones.';
  end if;

  if exists (
    select 1
    from public.organization_members as member
    join auth.users as auth_user
      on auth_user.id = member.user_id
    where member.organization_id =
      target_organization_id
      and lower(btrim(auth_user.email)) =
        normalized_email
  ) then
    raise exception using
      errcode = 'P0001',
      message = 'No se pudo crear la invitación.';
  end if;

  insert into public.organization_invitations (
    organization_id,
    email,
    role,
    status,
    invited_by,
    token_hash,
    expires_at,
    last_sent_at,
    send_count
  )
  values (
    target_organization_id,
    normalized_email,
    normalized_role,
    'pending',
    actor_user_id,
    invitation_token_hash,
    invitation_expires_at,
    now(),
    1
  )
  returning *
  into inserted_invitation;

  return jsonb_build_object(
    'id', inserted_invitation.id,
    'email', inserted_invitation.email,
    'role', inserted_invitation.role,
    'expires_at', inserted_invitation.expires_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.list_organization_invitations(target_organization_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid := auth.uid();
  caller_role text;
  invitations jsonb;
begin
  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  caller_role :=
    private.invitation_actor_role(
      target_organization_id,
      current_user_id
    );

  if caller_role is null then
    raise exception using
      errcode = '42501',
      message =
        'No tienes permiso para consultar invitaciones.';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', invitation.id,
        'email', invitation.email,
        'role', invitation.role,
        'status',
          case
            when invitation.status = 'pending'
             and invitation.expires_at <= now()
              then 'expired'
            else invitation.status
          end,
        'expires_at', invitation.expires_at,
        'accepted_at', invitation.accepted_at,
        'created_at', invitation.created_at,
        'updated_at', invitation.updated_at,
        'last_sent_at', invitation.last_sent_at,
        'send_count', invitation.send_count
      )
      order by invitation.created_at desc
    ),
    '[]'::jsonb
  )
  into invitations
  from public.organization_invitations as invitation
  where invitation.organization_id =
    target_organization_id;

  return jsonb_build_object(
    'items', invitations,
    'caller_role', caller_role
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.resend_organization_invitation(target_invitation_id uuid, invitation_token_hash bytea, invitation_expires_at timestamp with time zone, actor_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  initial_invitation record;
  initial_actor_role text;
  locked_actor_role text;

  locked_invitation
    public.organization_invitations%rowtype;
begin
  if target_invitation_id is null
     or actor_user_id is null
     or invitation_token_hash is null
     or octet_length(invitation_token_hash) <> 32
     or invitation_expires_at <= now()
     or invitation_expires_at >
       now() + interval '14 days'
  then
    raise exception using
      errcode = '22023',
      message = 'La solicitud de reenvío no es válida.';
  end if;

  select
    invitation.organization_id,
    invitation.role
  into initial_invitation
  from public.organization_invitations as invitation
  where invitation.id = target_invitation_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'No se pudo procesar la invitación.';
  end if;

  initial_actor_role :=
    private.invitation_actor_role(
      initial_invitation.organization_id,
      actor_user_id
    );

  if initial_actor_role is null
     or (
       initial_actor_role = 'admin'
       and initial_invitation.role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message =
        'No tienes permiso para reenviar esta invitación.';
  end if;

  perform *
  from private.lock_member_plan_context(
    initial_invitation.organization_id,
    true
  );

  select invitation.*
  into locked_invitation
  from public.organization_invitations as invitation
  where invitation.id = target_invitation_id
    and invitation.organization_id =
      initial_invitation.organization_id
  for update;

  if not found
     or locked_invitation.role is distinct from
       initial_invitation.role
  then
    raise exception using
      errcode = '40001',
      message =
        'La invitación cambió durante la operación. Intenta nuevamente.';
  end if;

  select member.role
  into locked_actor_role
  from public.organization_members as member
  where member.organization_id =
      initial_invitation.organization_id
    and member.user_id = actor_user_id
    and member.status = 'active'
  for share;

  if locked_actor_role is null
     or locked_actor_role is distinct from
       initial_actor_role
     or (
       locked_actor_role = 'admin'
       and locked_invitation.role = 'owner'
     )
  then
    raise exception using
      errcode = '40001',
      message =
        'Tus permisos cambiaron durante la operación. Intenta nuevamente.';
  end if;

  if locked_invitation.status not in (
       'pending', 'expired'
     )
     or locked_invitation.last_sent_at >
       now() - interval '60 seconds'
     or locked_invitation.send_count >= 5
  then
    raise exception using
      errcode = 'P0001',
      message = 'No se pudo reenviar la invitación.';
  end if;

  update public.organization_invitations as invitation
  set
    status = 'pending',
    token_hash = invitation_token_hash,
    expires_at = invitation_expires_at,
    accepted_by = null,
    accepted_at = null,
    revoked_at = null,
    last_sent_at = now(),
    send_count = invitation.send_count + 1,
    updated_at = now()
  where invitation.id = target_invitation_id
  returning *
  into locked_invitation;

  return jsonb_build_object(
    'id', locked_invitation.id,
    'organization_id', locked_invitation.organization_id,
    'email', locked_invitation.email,
    'role', locked_invitation.role,
    'expires_at', locked_invitation.expires_at
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.revoke_organization_invitation(target_invitation_id uuid, actor_user_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  initial_invitation record;
  initial_actor_role text;
  locked_actor_role text;

  locked_invitation
    public.organization_invitations%rowtype;
begin
  select
    invitation.organization_id,
    invitation.role
  into initial_invitation
  from public.organization_invitations as invitation
  where invitation.id = target_invitation_id;

  if not found then
    raise exception using
      errcode = 'P0001',
      message = 'No se pudo procesar la invitación.';
  end if;

  initial_actor_role :=
    private.invitation_actor_role(
      initial_invitation.organization_id,
      actor_user_id
    );

  if initial_actor_role is null
     or (
       initial_actor_role = 'admin'
       and initial_invitation.role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message =
        'No tienes permiso para revocar esta invitación.';
  end if;

  perform 1
  from public.organizations as organization
  where organization.id =
    initial_invitation.organization_id
  for update;

  select invitation.*
  into locked_invitation
  from public.organization_invitations as invitation
  where invitation.id = target_invitation_id
    and invitation.organization_id =
      initial_invitation.organization_id
  for update;

  select member.role
  into locked_actor_role
  from public.organization_members as member
  where member.organization_id =
      initial_invitation.organization_id
    and member.user_id = actor_user_id
    and member.status = 'active'
  for share;

  if locked_actor_role is null
     or locked_actor_role is distinct from
       initial_actor_role
     or locked_invitation.status <> 'pending'
     or (
       locked_actor_role = 'admin'
       and locked_invitation.role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message = 'No se pudo revocar la invitación.';
  end if;

  update public.organization_invitations as invitation
  set
    status = 'revoked',
    revoked_at = now(),
    updated_at = now()
  where invitation.id = target_invitation_id;

  return jsonb_build_object(
    'id', target_invitation_id,
    'revoked', true
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.accept_organization_invitation(invitation_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  current_user_id uuid := auth.uid();
  current_email text;
  calculated_hash bytea;

  initial_invitation record;

  locked_invitation
    public.organization_invitations%rowtype;

  locked_inviter_role text;
begin
  if current_user_id is null then
    raise exception using
      errcode = '42501',
      message = 'Autenticación requerida.';
  end if;

  /*
   * Contrato obligatorio para Paso B:
   *
   * 1. Generar exactamente 32 bytes aleatorios.
   * 2. Codificarlos como base64url sin padding.
   * 3. El resultado debe tener exactamente 43 caracteres.
   * 4. Calcular SHA-256 sobre la cadena base64url de
   *    43 caracteres codificada como UTF-8.
   * 5. Guardar solamente los 32 bytes resultantes del hash.
   *
   * No calcular el hash directamente sobre los 32 bytes
   * aleatorios originales.
   */
  if coalesce(invitation_token, '') !~
       '^[A-Za-z0-9_-]{43}$'
  then
    raise exception using
      errcode = 'P0001',
      message =
        'La invitación no es válida o ha expirado.';
  end if;

  calculated_hash :=
    extensions.digest(
      convert_to(invitation_token, 'UTF8'),
      'sha256'
    );

  select
    invitation.id,
    invitation.organization_id
  into initial_invitation
  from public.organization_invitations as invitation
  where invitation.token_hash = calculated_hash
    and invitation.status = 'pending'
    and invitation.expires_at > now();

  if not found then
    raise exception using
      errcode = 'P0001',
      message =
        'La invitación no es válida o ha expirado.';
  end if;

  perform *
  from private.lock_member_plan_context(
    initial_invitation.organization_id,
    true
  );

  select invitation.*
  into locked_invitation
  from public.organization_invitations as invitation
  where invitation.id = initial_invitation.id
    and invitation.organization_id =
      initial_invitation.organization_id
    and invitation.token_hash = calculated_hash
    and invitation.status = 'pending'
    and invitation.expires_at > now()
  for update;

  if not found then
    raise exception using
      errcode = 'P0001',
      message =
        'La invitación no es válida o ha expirado.';
  end if;

  select member.role
  into locked_inviter_role
  from public.organization_members as member
  where member.organization_id =
      locked_invitation.organization_id
    and member.user_id =
      locked_invitation.invited_by
    and member.status = 'active'
    and member.role in ('owner', 'admin')
  for share;

  if locked_inviter_role is null
     or (
       locked_inviter_role = 'admin'
       and locked_invitation.role = 'owner'
     )
  then
    raise exception using
      errcode = '42501',
      message =
        'La invitación ya no puede aceptarse.';
  end if;

  select lower(btrim(auth_user.email))
  into current_email
  from auth.users as auth_user
  where auth_user.id = current_user_id
    and auth_user.email is not null
    and auth_user.deleted_at is null
    and auth_user.is_anonymous = false
    and coalesce(
      auth_user.email_confirmed_at,
      auth_user.confirmed_at
    ) is not null
    and (
      auth_user.banned_until is null
      or auth_user.banned_until <= now()
    );

  if current_email is null
     or current_email <> locked_invitation.email
  then
    raise exception using
      errcode = '42501',
      message =
        'La invitación no es válida para esta cuenta.';
  end if;

  if exists (
    select 1
    from public.organization_members as member
    where member.organization_id =
      locked_invitation.organization_id
      and member.user_id = current_user_id
  ) then
    raise exception using
      errcode = '23505',
      message =
        'La cuenta ya pertenece a la organización.';
  end if;

  insert into public.organization_members (
    organization_id,
    user_id,
    role,
    status,
    created_by
  )
  values (
    locked_invitation.organization_id,
    current_user_id,
    locked_invitation.role,
    'active',
    locked_invitation.invited_by
  );

  update public.organization_invitations as invitation
  set
    status = 'accepted',
    accepted_by = current_user_id,
    accepted_at = now(),
    updated_at = now()
  where invitation.id = locked_invitation.id;

  return jsonb_build_object(
    'organization_id',
      locked_invitation.organization_id,
    'role',
      locked_invitation.role,
    'status',
      'accepted'
  );
end;
$function$;

alter table public.organization_invitations enable row level security;

-- El estado remoto no contiene policies sobre organization_invitations.
revoke all privileges
on table public.organization_invitations
from anon, authenticated;

-- Conserva el estado efectivo actual: service_role opera mediante RPC
-- SECURITY DEFINER y no tiene CRUD directo sobre la tabla.
revoke select, insert, update, delete
on table public.organization_invitations
from service_role;

revoke all
on function private.invitation_actor_role(uuid, uuid)
from public, anon, authenticated, service_role;

revoke all
on function public.create_organization_invitation(
  uuid, text, text, bytea, timestamp with time zone, uuid
)
from public, anon, authenticated, service_role;

grant execute
on function public.create_organization_invitation(
  uuid, text, text, bytea, timestamp with time zone, uuid
)
to service_role;

revoke all
on function public.list_organization_invitations(uuid)
from public, anon, authenticated, service_role;

grant execute
on function public.list_organization_invitations(uuid)
to authenticated;

revoke all
on function public.resend_organization_invitation(
  uuid, bytea, timestamp with time zone, uuid
)
from public, anon, authenticated, service_role;

grant execute
on function public.resend_organization_invitation(
  uuid, bytea, timestamp with time zone, uuid
)
to service_role;

revoke all
on function public.revoke_organization_invitation(uuid, uuid)
from public, anon, authenticated, service_role;

grant execute
on function public.revoke_organization_invitation(uuid, uuid)
to service_role;

revoke all
on function public.accept_organization_invitation(text)
from public, anon, authenticated, service_role;

grant execute
on function public.accept_organization_invitation(text)
to authenticated;

grant select (id, name)
on table public.organizations
to service_role;

commit;
