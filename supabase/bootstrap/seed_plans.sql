-- Seed reproducible del catálogo comercial de planes de Digital Card.
-- Fuente: estado efectivo de producción del 17 de agosto de 2026.
-- No contiene planes de prueba, suscripciones ni datos de clientes.

begin;

DO $plans_seed_preflight$
BEGIN
  IF to_regclass('public.plans') IS NULL THEN
    RAISE EXCEPTION
      'El seed requiere public.plans. Aplica primero la baseline protegida.';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint AS constraint_definition
    WHERE constraint_definition.conrelid = 'public.plans'::regclass
      AND constraint_definition.conname = 'plans_code_key'
      AND constraint_definition.contype = 'u'
      AND pg_get_constraintdef(constraint_definition.oid, true) = 'UNIQUE (code)'
  ) THEN
    RAISE EXCEPTION
      'El seed requiere el constraint estable UNIQUE (code) de public.plans.';
  END IF;
END;
$plans_seed_preflight$;

insert into public.plans (
  id,
  code,
  name,
  description,
  max_cards,
  max_members,
  lead_capture_enabled,
  analytics_enabled,
  analytics_history_days,
  qr_enabled,
  profile_image_enabled,
  logo_image_enabled,
  cover_image_enabled,
  csv_export_enabled,
  visual_customization_level,
  video_enabled,
  payment_card_enabled,
  support_level,
  capabilities,
  configuration_notes,
  status,
  sort_order,
  created_at,
  updated_at
)
values
  (
    '70000000-0000-4000-8000-000000000001'::uuid,
    'conecta-card-esencial',
    'Conecta Card Esencial',
    'Configuración inicial para presencia digital individual básica.',
    1,
    1,
    false,
    false,
    null,
    true,
    true,
    false,
    false,
    false,
    'basic',
    false,
    false,
    'standard',
    '{"qr_logo_enabled":false,"qr_custom_colors":false,"qr_premium_styles":false,"commercially_final":false,"configuration_status":"initial_editable"}'::jsonb,
    'Configuración inicial editable; no constituye una decisión comercial definitiva.',
    'active',
    1,
    '2026-08-14 17:33:27.825281+00'::timestamptz,
    '2026-08-14 22:22:38.301771+00'::timestamptz
  ),
  (
    '70000000-0000-4000-8000-000000000002'::uuid,
    'conecta-card-independiente',
    'Conecta Card Independiente',
    'Configuración inicial para profesionales independientes.',
    3,
    1,
    true,
    true,
    30,
    true,
    true,
    true,
    true,
    true,
    'standard',
    false,
    false,
    'standard',
    '{"qr_logo_enabled":false,"qr_custom_colors":true,"qr_premium_styles":false,"commercially_final":false,"configuration_status":"initial_editable"}'::jsonb,
    'Configuración inicial editable; no constituye una decisión comercial definitiva.',
    'active',
    2,
    '2026-08-14 17:33:27.825281+00'::timestamptz,
    '2026-08-14 22:22:38.301771+00'::timestamptz
  ),
  (
    '70000000-0000-4000-8000-000000000003'::uuid,
    'conecta-card-pyme',
    'Conecta Card PyME',
    'Configuración inicial para pequeñas y medianas organizaciones.',
    15,
    10,
    true,
    true,
    null,
    true,
    true,
    true,
    true,
    true,
    'advanced',
    true,
    true,
    'priority',
    '{"qr_logo_enabled":true,"qr_custom_colors":true,"qr_premium_styles":false,"commercially_final":false,"configuration_status":"initial_editable"}'::jsonb,
    'Configuración inicial editable; no constituye una decisión comercial definitiva.',
    'active',
    3,
    '2026-08-14 17:33:27.825281+00'::timestamptz,
    '2026-08-14 22:22:38.301771+00'::timestamptz
  ),
  (
    '70000000-0000-4000-8000-000000000004'::uuid,
    'conecta-card-empresarial',
    'Conecta Card Empresarial',
    'Configuración inicial para organizaciones empresariales.',
    100,
    50,
    true,
    true,
    null,
    true,
    true,
    true,
    true,
    true,
    'advanced',
    true,
    true,
    'sla',
    '{"qr_logo_enabled":true,"qr_custom_colors":true,"qr_premium_styles":true,"commercially_final":false,"configuration_status":"initial_editable"}'::jsonb,
    'Configuración inicial editable; no constituye una decisión comercial definitiva.',
    'active',
    4,
    '2026-08-14 17:33:27.825281+00'::timestamptz,
    '2026-08-14 22:22:38.301771+00'::timestamptz
  )
on conflict (code) do nothing;

DO $plans_seed_postflight$
BEGIN
  IF (
    SELECT count(*)
    FROM public.plans AS plan
    WHERE plan.code = ANY (ARRAY[
      'conecta-card-esencial',
      'conecta-card-independiente',
      'conecta-card-pyme',
      'conecta-card-empresarial'
    ]::text[])
  ) <> 4 THEN
    RAISE EXCEPTION
      'Postflight: no existen exactamente los cuatro códigos comerciales esperados.';
  END IF;

  IF EXISTS (
    WITH expected(payload) AS (
      VALUES
        ('{"id":"70000000-0000-4000-8000-000000000001","code":"conecta-card-esencial","name":"Conecta Card Esencial","description":"Configuración inicial para presencia digital individual básica.","max_cards":1,"max_members":1,"lead_capture_enabled":false,"analytics_enabled":false,"analytics_history_days":null,"qr_enabled":true,"profile_image_enabled":true,"logo_image_enabled":false,"cover_image_enabled":false,"csv_export_enabled":false,"visual_customization_level":"basic","video_enabled":false,"payment_card_enabled":false,"support_level":"standard","capabilities":{"qr_logo_enabled":false,"qr_custom_colors":false,"qr_premium_styles":false,"commercially_final":false,"configuration_status":"initial_editable"},"configuration_notes":"Configuración inicial editable; no constituye una decisión comercial definitiva.","status":"active","sort_order":1,"created_at":"2026-08-14T17:33:27.825281+00:00","updated_at":"2026-08-14T22:22:38.301771+00:00"}'::jsonb),
        ('{"id":"70000000-0000-4000-8000-000000000002","code":"conecta-card-independiente","name":"Conecta Card Independiente","description":"Configuración inicial para profesionales independientes.","max_cards":3,"max_members":1,"lead_capture_enabled":true,"analytics_enabled":true,"analytics_history_days":30,"qr_enabled":true,"profile_image_enabled":true,"logo_image_enabled":true,"cover_image_enabled":true,"csv_export_enabled":true,"visual_customization_level":"standard","video_enabled":false,"payment_card_enabled":false,"support_level":"standard","capabilities":{"qr_logo_enabled":false,"qr_custom_colors":true,"qr_premium_styles":false,"commercially_final":false,"configuration_status":"initial_editable"},"configuration_notes":"Configuración inicial editable; no constituye una decisión comercial definitiva.","status":"active","sort_order":2,"created_at":"2026-08-14T17:33:27.825281+00:00","updated_at":"2026-08-14T22:22:38.301771+00:00"}'::jsonb),
        ('{"id":"70000000-0000-4000-8000-000000000003","code":"conecta-card-pyme","name":"Conecta Card PyME","description":"Configuración inicial para pequeñas y medianas organizaciones.","max_cards":15,"max_members":10,"lead_capture_enabled":true,"analytics_enabled":true,"analytics_history_days":null,"qr_enabled":true,"profile_image_enabled":true,"logo_image_enabled":true,"cover_image_enabled":true,"csv_export_enabled":true,"visual_customization_level":"advanced","video_enabled":true,"payment_card_enabled":true,"support_level":"priority","capabilities":{"qr_logo_enabled":true,"qr_custom_colors":true,"qr_premium_styles":false,"commercially_final":false,"configuration_status":"initial_editable"},"configuration_notes":"Configuración inicial editable; no constituye una decisión comercial definitiva.","status":"active","sort_order":3,"created_at":"2026-08-14T17:33:27.825281+00:00","updated_at":"2026-08-14T22:22:38.301771+00:00"}'::jsonb),
        ('{"id":"70000000-0000-4000-8000-000000000004","code":"conecta-card-empresarial","name":"Conecta Card Empresarial","description":"Configuración inicial para organizaciones empresariales.","max_cards":100,"max_members":50,"lead_capture_enabled":true,"analytics_enabled":true,"analytics_history_days":null,"qr_enabled":true,"profile_image_enabled":true,"logo_image_enabled":true,"cover_image_enabled":true,"csv_export_enabled":true,"visual_customization_level":"advanced","video_enabled":true,"payment_card_enabled":true,"support_level":"sla","capabilities":{"qr_logo_enabled":true,"qr_custom_colors":true,"qr_premium_styles":true,"commercially_final":false,"configuration_status":"initial_editable"},"configuration_notes":"Configuración inicial editable; no constituye una decisión comercial definitiva.","status":"active","sort_order":4,"created_at":"2026-08-14T17:33:27.825281+00:00","updated_at":"2026-08-14T22:22:38.301771+00:00"}'::jsonb)
    )
    SELECT 1
    FROM expected
    LEFT JOIN public.plans AS plan
      ON plan.code = expected.payload ->> 'code'
    WHERE plan.id IS NULL
       OR to_jsonb(plan) IS DISTINCT FROM expected.payload
  ) THEN
    RAISE EXCEPTION
      'Postflight: UUID, campos o capacidades de uno o más planes no coinciden con producción.';
  END IF;
END;
$plans_seed_postflight$;

commit;
