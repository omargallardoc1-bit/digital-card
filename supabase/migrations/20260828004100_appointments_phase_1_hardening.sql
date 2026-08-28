-- Citas Fase 1 — endurecimiento posterior a activación controlada
begin;

revoke execute on function public.create_public_appointment(uuid,uuid,timestamptz,uuid,integer,text) from anon, authenticated;
grant execute on function public.create_public_appointment(uuid,uuid,timestamptz,uuid,integer,text) to service_role;

create index if not exists appointments_service_idx
  on public.appointments(service_id)
  where service_id is not null;

commit;
