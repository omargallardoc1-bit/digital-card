import { createClient } from 'npm:@supabase/supabase-js@2.57.4'

const MAX_BODY_BYTES = 2048
const MAX_EXPORT_ROWS = 10000
const PAGE_SIZE = 100
const EXACT_ORIGINS = new Set([
  'http://127.0.0.1:4173',
  'http://localhost:4173',
  'https://digital-card-mvp-three.vercel.app',
])
const VERCEL_PREVIEW_HOST = /^digital-card(?:-[a-z0-9-]+)?-digital-01dd\.vercel\.app$/
const ALLOWED_KEYS = new Set(['organization_id', 'card_id', 'sort_direction'])
const ALLOWED_ROLES = new Set(['owner', 'admin', 'editor'])
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
    'Access-Control-Expose-Headers': 'Content-Disposition',
    'Vary': 'Origin',
  }
}

function json(origin: string | null, status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), 'Content-Type': 'application/json; charset=utf-8' },
  })
}

function csvCell(value: unknown) {
  let text = String(value ?? '')
  if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`
  return `"${text.replaceAll('"', '""')}"`
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get('origin')
  if (!isAllowedOrigin(origin)) return json(null, 403, { error: 'Origen no permitido.' })
  if (req.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(origin) })
  if (req.method !== 'POST') return json(origin, 405, { error: 'Método no permitido.' })

  const authorization = req.headers.get('authorization') || ''
  if (!authorization.toLowerCase().startsWith('bearer ')) return json(origin, 401, { error: 'Se requiere autenticación.' })
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
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('invalid')
    body = parsed as Record<string, unknown>
  } catch {
    return json(origin, 400, { error: 'Solicitud no válida.' })
  }

  const keys = Object.keys(body)
  if (keys.some((key) => !ALLOWED_KEYS.has(key))) return json(origin, 400, { error: 'La solicitud contiene campos no permitidos.' })
  if (!keys.includes('organization_id')) return json(origin, 400, { error: 'Falta organization_id.' })

  const organizationId = typeof body.organization_id === 'string' ? body.organization_id.trim() : ''
  const cardId = typeof body.card_id === 'string' ? body.card_id.trim() : ''
  const sortDirection = typeof body.sort_direction === 'string' ? body.sort_direction.trim().toLowerCase() : 'desc'
  if (!UUID_PATTERN.test(organizationId) || (cardId && !UUID_PATTERN.test(cardId))) return json(origin, 400, { error: 'Identificador no válido.' })
  if (!['asc', 'desc'].includes(sortDirection)) return json(origin, 400, { error: 'Orden no válido.' })

  const supabaseUrl = Deno.env.get('SUPABASE_URL') || ''
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') || ''
  if (!supabaseUrl || !anonKey) return json(origin, 500, { error: 'No fue posible procesar la exportación.' })
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  })

  const { data: userData, error: userError } = await userClient.auth.getUser()
  const user = userData?.user
  if (userError || !user) return json(origin, 401, { error: 'La sesión no es válida.' })

  const { data: membership, error: membershipError } = await userClient
    .from('organization_members')
    .select('role,status')
    .eq('organization_id', organizationId)
    .eq('user_id', user.id)
    .eq('status', 'active')
    .maybeSingle()
  if (membershipError) return json(origin, 500, { error: 'No fue posible validar la organización.' })
  if (!membership || !ALLOWED_ROLES.has(membership.role)) return json(origin, 403, { error: 'No tienes permiso para exportar prospectos.' })

  const { data: subscription, error: subscriptionError } = await userClient
    .from('organization_subscriptions')
    .select('status,starts_at,expires_at,plans!inner(status,csv_export_enabled)')
    .eq('organization_id', organizationId)
    .in('status', ['trial', 'active', 'past_due'])
    .order('starts_at', { ascending: false })
    .limit(1)
    .maybeSingle()
  if (subscriptionError) return json(origin, 500, { error: 'No fue posible validar la suscripción.' })
  const plan = Array.isArray(subscription?.plans) ? subscription.plans[0] : subscription?.plans
  const now = Date.now()
  const usable = subscription &&
    ['trial', 'active', 'past_due'].includes(subscription.status) &&
    new Date(subscription.starts_at).getTime() <= now &&
    (!subscription.expires_at || new Date(subscription.expires_at).getTime() > now) &&
    plan?.status === 'active'
  if (!usable) return json(origin, 403, { error: 'La organización no tiene una suscripción utilizable.' })
  if (plan.csv_export_enabled !== true) return json(origin, 403, { error: 'El plan no incluye exportación CSV.' })

  const rows: Record<string, unknown>[] = []
  let page = 1
  let total = 0
  do {
    const { data, error } = await userClient.rpc('list_organization_prospects', {
      target_organization_id: organizationId,
      target_card_id: cardId || null,
      requested_page: page,
      requested_page_size: PAGE_SIZE,
      sort_direction: sortDirection,
    })
    if (error) return json(origin, 403, { error: error.message || 'No fue posible consultar los prospectos.' })
    const result = Array.isArray(data) ? data[0] : data
    total = Number(result?.total_count || 0)
    if (total > MAX_EXPORT_ROWS) return json(origin, 413, { error: 'La exportación supera el máximo de 10,000 filas.' })
    const items = Array.isArray(result?.items) ? result.items : []
    rows.push(...items)
    page += 1
  } while (rows.length < total)

  const csvRows = [
    ['Nombre', 'Teléfono', 'Correo', 'Tarjeta', 'Fecha', 'Source', 'Consentimiento', 'Versión de consentimiento'],
    ...rows.map((item) => [
      item.name,
      item.phone,
      item.email,
      item.card_name,
      item.created_at,
      item.source,
      item.consent_given === true ? 'Sí' : 'No',
      item.consent_version,
    ]),
  ]
  const csv = '\uFEFF' + csvRows.map((row) => row.map(csvCell).join(',')).join('\r\n')
  return new Response(csv, {
    status: 200,
    headers: {
      ...corsHeaders(origin),
      'Content-Type': 'text/csv; charset=utf-8',
      'Content-Disposition': 'attachment; filename="prospectos.csv"',
      'Cache-Control': 'no-store',
    },
  })
})
