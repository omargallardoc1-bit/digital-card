create or replace function public.create_public_prospect_appointment(
  target_card_id uuid,
  prospect_name text,
  prospect_phone text,
  prospect_email text default null::text,
  prospect_source text default 'public_card'::text,
  consent_given boolean default false,
  requested_at timestamptz default null::timestamptz,
  target_service_id uuid default null::uuid,
  requested_duration_minutes integer default 30,
  appointment_notes text default null::text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog'
as $function$
declare
  created_prospect_id uuid;
  created_appointment_id uuid;
begin
  created_prospect_id := public.create_public_prospect(
    target_card_id,
    prospect_name,
    prospect_phone,
    prospect_email,
    prospect_source,
    consent_given
  );

  created_appointment_id := public.create_public_appointment(
    target_card_id,
    created_prospect_id,
    requested_at,
    target_service_id,
    requested_duration_minutes,
    appointment_notes
  );

  return jsonb_build_object(
    'prospect_id', created_prospect_id,
    'appointment_id', created_appointment_id
  );
end;
$function$;

revoke all on function public.create_public_prospect_appointment(uuid,text,text,text,text,boolean,timestamptz,uuid,integer,text) from public, anon, authenticated;
grant execute on function public.create_public_prospect_appointment(uuid,text,text,text,text,boolean,timestamptz,uuid,integer,text) to service_role;
