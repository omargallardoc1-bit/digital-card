import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const encoder = new TextEncoder()
const toleranceSeconds = 300

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}

function hex(bytes: ArrayBuffer) {
  return Array.from(new Uint8Array(bytes)).map((b) => b.toString(16).padStart(2, '0')).join('')
}

function constantTimeEqual(a: string, b: string) {
  if (a.length !== b.length) return false
  let diff = 0
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return diff === 0
}

async function hmacSha256(secret: string, message: string) {
  const key = await crypto.subtle.importKey('raw', encoder.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  return hex(await crypto.subtle.sign('HMAC', key, encoder.encode(message)))
}

async function verifyStripeSignature(rawBody: string, signatureHeader: string, secret: string) {
  const parts = signatureHeader.split(',').map((part) => part.trim())
  const timestampPart = parts.find((part) => part.startsWith('t='))
  const signatures = parts.filter((part) => part.startsWith('v1=')).map((part) => part.slice(3))
  if (!timestampPart || signatures.length === 0) return false
  const timestamp = Number(timestampPart.slice(2))
  if (!Number.isFinite(timestamp)) return false
  const age = Math.abs(Math.floor(Date.now() / 1000) - timestamp)
  if (age > toleranceSeconds) return false
  const expected = await hmacSha256(secret, `${timestamp}.${rawBody}`)
  return signatures.some((candidate) => constantTimeEqual(candidate, expected))
}

function stripeId(value: unknown): string | null {
  if (typeof value === 'string') return value
  if (value && typeof value === 'object' && 'id' in value && typeof (value as { id?: unknown }).id === 'string') return (value as { id: string }).id
  return null
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' })

  const webhookSecret = Deno.env.get('STRIPE_INTERNATIONAL_WEBHOOK_SECRET')
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!webhookSecret || !supabaseUrl || !serviceRoleKey) return json(503, { error: 'webhook_not_configured' })

  const signature = req.headers.get('stripe-signature')
  if (!signature) return json(400, { error: 'missing_signature' })

  const rawBody = await req.text()
  if (!(await verifyStripeSignature(rawBody, signature, webhookSecret))) return json(400, { error: 'invalid_signature' })

  let event: any
  try { event = JSON.parse(rawBody) } catch { return json(400, { error: 'invalid_json' }) }
  if (!event?.id || !event?.type || !event?.data?.object) return json(400, { error: 'invalid_event' })

  const invoice = event.data.object
  const subscriptionId = stripeId(invoice.subscription ?? invoice.parent?.subscription_details?.subscription)
  const customerId = stripeId(invoice.customer)
  const db = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } })

  const { data: ingested, error: ingestError } = await db.rpc('ingest_payment_provider_webhook', {
    provider_name: 'stripe',
    event_id: event.id,
    event_type_name: event.type,
    customer_id: customerId,
    subscription_id: subscriptionId,
    is_livemode: Boolean(event.livemode),
    event_payload: event,
  })
  if (ingestError) return json(500, { error: 'ingest_failed' })

  const row = Array.isArray(ingested) ? ingested[0] : ingested
  if (!row?.webhook_event_id) return json(500, { error: 'missing_webhook_event_id' })
  if (row.inserted === false) return json(200, { received: true, duplicate: true })

  if (!['invoice.paid', 'invoice.payment_failed'].includes(event.type)) {
    await db.rpc('mark_payment_provider_webhook_result', {
      target_webhook_event_id: row.webhook_event_id,
      result_status: 'ignored',
      result_error: null,
    })
    return json(200, { received: true, ignored: true })
  }

  const amount = Number(invoice.amount_paid ?? 0) / 100
  const currency = typeof invoice.currency === 'string' ? invoice.currency.toUpperCase() : ''
  const paidAtSeconds = Number(invoice.status_transitions?.paid_at ?? event.created ?? 0)
  const paidAt = paidAtSeconds > 0 ? new Date(paidAtSeconds * 1000).toISOString() : null
  const periodEndSeconds = Number(invoice.lines?.data?.[0]?.period?.end ?? invoice.period_end ?? 0)
  const periodEnd = periodEndSeconds > 0 ? new Date(periodEndSeconds * 1000).toISOString() : null

  const { error: processError } = await db.rpc('process_stripe_invoice_webhook', {
    target_webhook_event_id: row.webhook_event_id,
    invoice_id: invoice.id ?? null,
    stripe_subscription_id: subscriptionId,
    payment_amount: amount,
    payment_currency: currency,
    payment_at: paidAt,
    invoice_period_end: periodEnd,
  })

  if (processError) {
    await db.rpc('mark_payment_provider_webhook_result', {
      target_webhook_event_id: row.webhook_event_id,
      result_status: 'failed',
      result_error: processError.message ?? 'processing_failed',
    })
    return json(500, { error: 'processing_failed' })
  }

  return json(200, { received: true })
})
