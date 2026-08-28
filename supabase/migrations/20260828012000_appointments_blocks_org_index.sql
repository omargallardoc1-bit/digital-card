create index if not exists appointment_blocks_org_time_idx
  on public.appointment_blocks(organization_id,starts_at,ends_at);
