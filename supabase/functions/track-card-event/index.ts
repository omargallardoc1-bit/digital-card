import { createClient } from 'npm:@supabase/supabase-js@2.57.4'

const MAX_BODY_BYTES = 2048
const MAX_METADATA_BYTES = 256
const EXACT_ORIGINS = new Set([
  'http://127.0.0.1:4173',
  'http://localhost:4173',
  'https://digital-card-mvp-three.vercel.app',
])
const VERCEL_PREVIEW_HOST = /^digital-card(?:-[a-z0-9-]+)?-digital-01dd\.vercel\.app$/
const ALLOWED_KEYS = new Set(['card_id', 'event_type', 'metadata'])
const ALLOWED_METADATA_KEYS = new Set(['source'])
const ALLOWED_SOURCES = new Set(['public_card', 'qr'])
const PUBLIC_EVENT_TYPES = new Set([
  'view',
  'whatsapp_click',
  'call_click',
  'email_click',
  'website_click',
])
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

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
  if (req.method !== 'POST') return json(origin, 405, { error: 'MÃ©todo no permitido.' })

  const contentType = req.headers.get('content-type') || ''
  if (!contentType.toLowerCase().startsWith('application/json')) return json(origin, 415, { error: 'Contenido no vÃ¡lido.' })
  const declaredLength = Number(req.headers.get('content-length') || 0)
  if (declaredLength > MAX_BODY_BYTES) return json(origin, 413, { error: 'Solicitud demasiado grande.' })

  let raw = ''
  try {
    raw = await req.text()
  } catch {
    return json(origin, 400, { error: 'Solicitud no vÃ¡lida.' })
  }
  if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) return json(origin, 413, { error: 'Solicitud demasiado grande.' })

  let body: Record<string, unknown>
  try {
    const parsed = JSON.parse(raw)
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('invalid body')
    body = parsed as Record<string, unknown>
  } catch {
    return json(origin, 400, { error: 'Solicitud no vÃ¡lida.' })
  }

  const keys = Object.keys(body)
  if (keys.some((key) => !ALLOWED_KEYS.has(key))) return json(origin, 400, { error: 'La solicitud contiene campos no permitidos.' })
  if (!['card_id', 'event_type'].every((key) => keys.includes(key))) return json(origin, 400, { error: 'Faltan campos obligatorios.' })

  const cardId = typeof body.card_id === 'string' ? body.card_id.trim() : ''
  const eventType = typeof body.event_type === 'string' ? body.event_type.trim() : ''
  if (!UUID_PATTERN.test(cardId) || !PUBLIC_EVENT_TYPES.has(eventType)) return json(origin, 400, { error: 'Datos no vÃ¡lidos.' })

  const metadataValue = body.metadata ?? {}
  if (!metadataValue || typeof metadataValue !== 'object' || Array.isArray(metadataValue)) return json(origin, 400, { error: 'Metadata no vÃ¡lida.' })
  const metadata = metadataValue as Record<string, unknown>
  const metadataKeys = Object.keys(metadata)
  if (metadataKeys.some((key) => !ALLOWED_METADATA_KEYS.has(key))) return json(origin, 400, { error: 'Metadata no permitida.' })
  if (metadata.source !== undefined && (typeof metadata.source !== 'string' || !ALLOWED_SOURCES.has(metadata.source))) return json(origin, 400, { error: 'Metadata no vÃ¡lida.' })
  if (new TextEncoder().encode(JSON.stringify(metadata)).byteLength > MAX_METADATA_BYTES) return json(origin, 400, { error: 'Metadata demasiado grande.' })

  const supabaseUrl = Deno.env.get('SUPABASE_URL') || ''
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
  if (!supabaseUrl || !serviceRoleKey) return json(origin, 500, { error: 'No fue posible procesar el evento.' })
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } })

  const { data: card, error: cardError } = await admin
    .from('digital_cards')
    .select('id')
    .eq('id', cardId)
    .eq('status', 'published')
    .maybeSingle()
  if (cardError) return json(origin, 500, { error: 'No fue posible procesar el evento.' })
  if (!card) return json(origin, 404, { error: 'Tarjeta no disponible.' })

  const { error: insertError } = await admin.from('card_events').insert({
    card_id: cardId,
    event_type: eventType,
    metadata: metadataKeys.length ? metadata : {},
  })
  if (insertError) return json(origin, 500, { error: 'No fue posible registrar el evento.' })

  return json(origin, 202, { ok: true })
})
