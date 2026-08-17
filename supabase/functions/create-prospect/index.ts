import { createClient } from 'npm:@supabase/supabase-js@2.57.4'

const MAX_BODY_BYTES = 4096
const EXACT_ORIGINS = new Set([
  'http://127.0.0.1:4173',
  'http://localhost:4173',
  'https://digital-card-mvp-three.vercel.app',
])
const VERCEL_PREVIEW_HOST = /^digital-card(?:-[a-z0-9-]+)?-digital-01dd\.vercel\.app$/
const ALLOWED_SOURCES = new Set(['public_card', 'qr'])
const ALLOWED_KEYS = new Set(['card_id', 'name', 'phone', 'email', 'source', 'consentimiento'])
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

function isAllowedOrigin(origin: string | null) {
  if (!origin) return false
  try {
    const url = new URL(origin)
    if (url.origin !== origin) return false
    if (EXACT_ORIGINS.has(url.origin)) return true
    return url.protocol === 'https:' &&
      url.port === '' &&
      VERCEL_PREVIEW_HOST.test(url.hostname.toLowerCase())
  } catch {
    return false
  }
}

function corsHeaders(origin: string | null) {
  return {
    'Access-Control-Allow-Origin': origin || '',
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  }
}

function json(origin: string | null, status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), 'Content-Type': 'application/json; charset=utf-8' },
  })
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin')
  if (!isAllowedOrigin(origin)) return json(null, 403, { error: 'Origen no permitido.' })
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(origin) })
  if (req.method !== 'POST') return json(origin, 405, { error: 'Método no permitido.' })

  const contentType = req.headers.get('content-type') || ''
  if (!contentType.toLowerCase().startsWith('application/json')) return json(origin, 415, { error: 'Contenido no válido.' })
  const declaredLength = Number(req.headers.get('content-length') || 0)
  if (declaredLength > MAX_BODY_BYTES) return json(origin, 413, { error: 'Solicitud demasiado grande.' })

  let raw = ''
  try {
    raw = await req.text()
  } catch {
    return json(origin, 400, { error: 'Solicitud no válida.' })
  }
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) return json(origin, 413, { error: 'Solicitud demasiado grande.' })

  let body: Record<string, unknown>
  try {
    const parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('invalid body')
    body = parsed as Record<string, unknown>
  } catch {
    return json(origin, 400, { error: 'Solicitud no válida.' })
  }

  const keys = Object.keys(body)
  if (keys.some((key) => !ALLOWED_KEYS.has(key))) return json(origin, 400, { error: 'La solicitud contiene campos no permitidos.' })
  if (!['card_id', 'name', 'phone', 'source', 'consentimiento'].every((key) => keys.includes(key))) {
    return json(origin, 400, { error: 'Faltan campos obligatorios.' })
  }

  const cardId = typeof body.card_id === 'string' ? body.card_id.trim() : ''
  const name = typeof body.name === 'string' ? body.name.trim() : ''
  const phone = typeof body.phone === 'string' ? body.phone.trim() : ''
  const email = typeof body.email === 'string' ? body.email.trim() : ''
  const source = typeof body.source === 'string' ? body.source.trim().toLowerCase() : ''

  if (!UUID_PATTERN.test(cardId)) return json(origin, 400, { error: 'Datos no válidos.' })
  if (!name || name.length > 120) return json(origin, 400, { error: 'El nombre es obligatorio y debe tener máximo 120 caracteres.' })
  if (!phone || phone.length > 40) return json(origin, 400, { error: 'El teléfono es obligatorio y debe tener máximo 40 caracteres.' })
  if (email.length > 254 || (email && !EMAIL_PATTERN.test(email))) return json(origin, 400, { error: 'El correo no es válido.' })
  if (!ALLOWED_SOURCES.has(source)) return json(origin, 400, { error: 'La fuente no es válida.' })
  if (body.consentimiento !== true) return json(origin, 400, { error: 'Debes aceptar el aviso de consentimiento.' })

  const supabaseUrl = Deno.env.get('SUPABASE_URL') || ''
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
  if (!supabaseUrl || !serviceRoleKey) return json(origin, 500, { error: 'No fue posible procesar la solicitud.' })
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } })

  const { error: createError } = await admin.rpc('create_public_prospect', {
    target_card_id: cardId,
    prospect_name: name,
    prospect_phone: phone,
    prospect_email: email || null,
    prospect_source: source,
    consent_given: true,
  })
  if (createError) return json(origin, 500, { error: 'No fue posible guardar tus datos.' })

  return json(origin, 201, { ok: true })
})
