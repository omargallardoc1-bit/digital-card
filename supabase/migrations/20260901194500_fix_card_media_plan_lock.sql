-- Fix media plan locking: the function receives an organization id, not a card id.

CREATE OR REPLACE FUNCTION private.lock_card_media_plan(target_organization_id uuid, media_type text)
 RETURNS TABLE(subscription_status text, capability_enabled boolean)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog'
AS $function$
declare
  locked_organization_id uuid;
  locked_subscription_id uuid;
  locked_plan_id uuid;
begin
  if target_organization_id is null or media_type not in ('profile','logo','cover') then return; end if;

  select organization.id
  into locked_organization_id
  from public.organizations organization
  where organization.id=target_organization_id and organization.status='active'
  for update;

  if locked_organization_id is null then return; end if;

  select subscription.id into locked_subscription_id
  from public.organization_subscriptions subscription
  where subscription.organization_id=locked_organization_id
    and subscription.status in ('trial','active','past_due')
    and subscription.starts_at<=now()
    and (subscription.expires_at is null or subscription.expires_at>now())
  order by subscription.starts_at desc limit 1 for update;

  if locked_subscription_id is null then return; end if;

  select subscription.plan_id into locked_plan_id
  from public.organization_subscriptions subscription
  where subscription.id=locked_subscription_id;

  perform 1 from public.plans plan where plan.id=locked_plan_id and plan.status='active' for update;

  if not found then return; end if;

  return query
  select subscription.status,
    case media_type
      when 'profile' then plan.profile_image_enabled
      when 'logo' then plan.logo_image_enabled
      when 'cover' then plan.cover_image_enabled
    end
  from public.organization_subscriptions subscription
  join public.plans plan on plan.id=locked_plan_id
  where subscription.id=locked_subscription_id and plan.status='active';
end;
$function$;

revoke all on function private.lock_card_media_plan(uuid,text) from public, anon, authenticated, service_role;
grant execute on function private.lock_card_media_plan(uuid,text) to authenticated;
