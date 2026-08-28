-- Rollback manual de Citas Fase 1.
-- Ejecutar solo si se decide retirar por completo el backend de citas.
begin;

drop function if exists public.update_organization_appointment(uuid,uuid,text,timestamptz,text);
drop function if exists public.list_organization_appointments(uuid,uuid,timestamptz,timestamptz);
drop function if exists public.create_public_appointment(uuid,uuid,timestamptz,uuid,integer,text);
drop table if exists public.appointments;

commit;

-- Nota: la Edge Function `create-appointment` debe eliminarse o desactivarse por separado.
-- La versión 12 de `create-prospect` es retrocompatible; puede mantenerse aunque se retire Citas.
