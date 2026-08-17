import "jsr:@supabase/functions-js/edge-runtime.d.ts"
import { createClient } from "npm:@supabase/supabase-js@2.57.4"

const PUBLIC_SITE_ORIGIN = "https://mxbusinesscard.com"
const EXACT_ORIGINS = new Set([
  "http://127.0.0.1:4173",
  "http://localhost:4173",
  "https://digital-card-mvp-three.vercel.app",
  "https://digital-card-wine.vercel.app",
  PUBLIC_SITE_ORIGIN,
])
const VERCEL_PREVIEW_HOST = /^digital-card(?:-[a-z0-9-]+)?-digital-01dd\.vercel\.app$/
const ALLOWED_ROLES = new Set(["owner", "admin", "editor", "viewer"])
const FORBIDDEN_IDENTITY_FIELDS = new Set(["actor_user_id", "user_id", "invited_by", "accepted_by"])
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
const EMAIL_PATTERN = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const MAX_REQUEST_BYTES = 4096
const INVITATION_LIFETIME_MS = 7 * 24 * 60 * 60 * 1000

type Action = "create" | "resend" | "revoke"
type JsonObject = Record<string, unknown>

class PublicError extends Error {
  constructor(message: string, readonly status = 400) {
    super(message)
  }
}

class EmailProviderError extends Error {
  constructor(readonly providerStatus: number, readonly providerBody: string) {
    super("email_provider_rejected")
  }
}

function isAllowedOrigin(value: string | null): value is string {
  if (!value) return false
  try {
    const parsed = new URL(value)
    if (parsed.origin !== value) return false
    if (EXACT_ORIGINS.has(parsed.origin)) return true
    return parsed.protocol === "https:" && parsed.port === "" &&
      VERCEL_PREVIEW_HOST.test(parsed.hostname.toLowerCase())
  } catch {
    return false
  }
}

function corsHeaders(origin: string) {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  }
}

function jsonResponse(body: JsonObject, status: number, origin: string) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(origin),
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  })
}

function hasExactKeys(body: JsonObject, expected: string[]) {
  const received = Object.keys(body).sort()
  const allowed = [...expected].sort()
  return received.length === allowed.length &&
    received.every((key, index) => key === allowed[index])
}

function escapeHtml(value: string) {
  return value.replace(/[&<>"']/g, (character) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    '"': "&quot;",
    "'": "&#039;",
  })[character]!)
}

function normalizeEmail(value: unknown) {
  if (typeof value !== "string") throw new PublicError("Correo inválido.")
  const email = value.trim().toLowerCase()
  if (!email || email.length > 254 || !EMAIL_PATTERN.test(email)) {
    throw new PublicError("Correo inválido.")
  }
  return email
}

function requireUuid(value: unknown, message: string) {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    throw new PublicError(message)
  }
  return value
}

async function createToken() {
  const randomBytes = crypto.getRandomValues(new Uint8Array(32))
  const token = btoa(String.fromCharCode(...randomBytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/g, "")
  if (token.length !== 43) throw new Error("token_generation_failed")
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token))
  const hashHex = Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("")
  return { token, tokenHash: `\\x${hashHex}` }
}

function safeHeaderValue(value: string, fallback: string) {
  const normalized = value.trim()
  if (!normalized || normalized.length > 100 || /[\r\n]/.test(normalized)) return fallback
  return normalized
}

async function sendInvitationEmail(input: {
  to: string
  organizationName: string
  role: string
  invitationUrl: string
  expiresAt: string
}) {
  const apiKey = Deno.env.get("RESEND_API_KEY")
  const fromEmail = Deno.env.get("INVITATION_FROM_EMAIL")
  const fromName = safeHeaderValue(
    Deno.env.get("INVITATION_FROM_NAME") || "MX Business Card",
    "MX Business Card",
  )
  const replyTo = Deno.env.get("INVITATION_REPLY_TO")?.trim()
  if (!apiKey || !fromEmail || !EMAIL_PATTERN.test(fromEmail) || /[\r\n]/.test(fromEmail)) {
    throw new Error("email_provider_not_configured")
  }

  const organizationName = escapeHtml(input.organizationName)
  const role = escapeHtml(input.role)
  const invitationUrl = escapeHtml(input.invitationUrl)
  const expiration = new Intl.DateTimeFormat("es-MX", {
    dateStyle: "long",
    timeStyle: "short",
    timeZone: "America/Mazatlan",
  }).format(new Date(input.expiresAt))

  const payload: JsonObject = {
    from: `${fromName} <${fromEmail}>`,
    to: [input.to],
    subject: `Te invitaron a unirte a ${input.organizationName}`,
    html: `<!doctype html><html lang="es"><body style="font-family:Arial,sans-serif;color:#172033"><h1>Invitación a ${organizationName}</h1><p>Te han invitado a formar parte de <strong>${organizationName}</strong> en MX Business Card con el rol <strong>${role}</strong>.</p><p style="margin:28px 0"><a href="${invitationUrl}" style="display:inline-block;background:#7c3aed;color:#fff;padding:13px 20px;border-radius:8px;text-decoration:none;font-weight:700">Aceptar invitación</a></p><p>Esta invitación vence el ${escapeHtml(expiration)} y solo puede utilizarse una vez.</p><p>Si todavía no tienes una cuenta, podrás crearla antes de completar la aceptación. El correo de tu cuenta debe coincidir con el destinatario de esta invitación.</p><p>Si no reconoces esta invitación, ignora este mensaje. No se realizará ningún cambio.</p><p>Si el botón no funciona, abre este enlace:<br><a href="${invitationUrl}">${invitationUrl}</a></p></body></html>`,
    text: [
      `Te invitaron a unirte a ${input.organizationName}.`,
      `Rol: ${input.role}.`,
      `Acepta la invitación: ${input.invitationUrl}`,
      `Vence: ${expiration}.`,
      "Si no reconoces esta invitación, ignora el mensaje.",
    ].join("\n\n"),
  }
  if (replyTo && EMAIL_PATTERN.test(replyTo) && !/[\r\n]/.test(replyTo)) payload.reply_to = replyTo

  const response = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  })
  if (!response.ok) {
    let providerBody = ""
    try {
      providerBody = await response.text()
    } catch {
      providerBody = "unreadable_response"
    }
    const safeProviderBody = providerBody
      .replace(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi, "[email]")
      .replace(/re_[A-Za-z0-9_-]+/g, "[redacted]")
      .slice(0, 1000)
    console.error("resend_rejected", {
      status: response.status,
      statusText: response.statusText,
      body: safeProviderBody,
    })
    throw new EmailProviderError(response.status, safeProviderBody)
  }
}

const RPC_MESSAGES: Record<string, { status: number; message: string }> = {
  "La solicitud de invitación no es válida.": { status: 400, message: "La solicitud de invitación no es válida." },
  "No tienes permiso para crear esta invitación.": { status: 403, message: "No tienes permiso para crear esta invitación." },
  "Ya existe una invitación pendiente para ese correo.": { status: 409, message: "Ya existe una invitación pendiente para ese correo." },
  "Se alcanzó temporalmente el límite de invitaciones.": { status: 429, message: "Se alcanzó temporalmente el límite de invitaciones." },
  "No se pudo crear la invitación.": { status: 400, message: "No se pudo crear la invitación." },
  "La solicitud de reenvío no es válida.": { status: 400, message: "La solicitud de reenvío no es válida." },
  "No tienes permiso para reenviar esta invitación.": { status: 403, message: "No tienes permiso para reenviar esta invitación." },
  "No se pudo reenviar la invitación.": { status: 409, message: "No se pudo reenviar la invitación." },
  "No tienes permiso para revocar esta invitación.": { status: 403, message: "No tienes permiso para revocar esta invitación." },
  "No se pudo revocar la invitación.": { status: 409, message: "No se pudo revocar la invitación." },
  "No se pudo procesar la invitación.": { status: 404, message: "No se pudo procesar la invitación." },
  "Tus permisos cambiaron durante la operación. Intenta nuevamente.": { status: 409, message: "Tus permisos cambiaron durante la operación. Intenta nuevamente." },
  "La invitación cambió durante la operación. Intenta nuevamente.": { status: 409, message: "La invitación cambió durante la operación. Intenta nuevamente." },
}

function rpcPublicError(error: unknown) {
  const message = typeof error === "object" && error && "message" in error
    ? String((error as { message?: unknown }).message || "")
    : ""
  return RPC_MESSAGES[message] || { status: 400, message: "No fue posible procesar la invitación." }
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("Origin")
  if (!isAllowedOrigin(origin)) {
    return new Response(JSON.stringify({ error: "Origen no autorizado." }), {
      status: 403,
      headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
    })
  }
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders(origin) })
  if (request.method !== "POST") return jsonResponse({ error: "Método no permitido." }, 405, origin)

  const contentType = request.headers.get("Content-Type") || ""
  if (!contentType.toLowerCase().startsWith("application/json")) {
    return jsonResponse({ error: "Contenido no válido." }, 415, origin)
  }
  const contentLength = Number(request.headers.get("Content-Length") || "0")
  if (!Number.isFinite(contentLength) || contentLength > MAX_REQUEST_BYTES) {
    return jsonResponse({ error: "Solicitud demasiado grande." }, 413, origin)
  }
  const authorization = request.headers.get("Authorization")
  if (!authorization?.toLowerCase().startsWith("bearer ")) {
    return jsonResponse({ error: "Sesión requerida." }, 401, origin)
  }

  let body: JsonObject
  try {
    const rawBody = await request.text()
    if (new TextEncoder().encode(rawBody).byteLength > MAX_REQUEST_BYTES) {
      return jsonResponse({ error: "Solicitud demasiado grande." }, 413, origin)
    }
    const parsed = JSON.parse(rawBody)
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("invalid_body")
    body = parsed as JsonObject
  } catch {
    return jsonResponse({ error: "Solicitud inválida." }, 400, origin)
  }

  for (const key of FORBIDDEN_IDENTITY_FIELDS) {
    if (Object.hasOwn(body, key)) return jsonResponse({ error: "Solicitud inválida." }, 400, origin)
  }
  const action = body.action
  if (action !== "create" && action !== "resend" && action !== "revoke") {
    return jsonResponse({ error: "Acción inválida." }, 400, origin)
  }
  const expectedKeys: Record<Action, string[]> = {
    create: ["action", "organization_id", "email", "role"],
    resend: ["action", "invitation_id"],
    revoke: ["action", "invitation_id"],
  }
  if (!hasExactKeys(body, expectedKeys[action])) {
    return jsonResponse({ error: "La solicitud contiene propiedades inválidas." }, 400, origin)
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")
  const serviceRole = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !anonKey || !serviceRole) {
    return jsonResponse({ error: "Servicio temporalmente no disponible." }, 503, origin)
  }
  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  })
  const { data: { user }, error: userError } = await userClient.auth.getUser()
  if (userError || !user) return jsonResponse({ error: "Sesión inválida." }, 401, origin)

  const admin = createClient(supabaseUrl, serviceRole, {
    auth: { persistSession: false, autoRefreshToken: false },
  })

  try {
    if (action === "revoke") {
      const invitationId = requireUuid(body.invitation_id, "Invitación inválida.")
      const { data, error } = await admin.rpc("revoke_organization_invitation", {
        target_invitation_id: invitationId,
        actor_user_id: user.id,
      })
      if (error) {
        const publicError = rpcPublicError(error)
        return jsonResponse({ ok: false, error: publicError.message }, publicError.status, origin)
      }
      return jsonResponse({ ok: true, invitation_id: data.id, status: "revoked" }, 200, origin)
    }

    const { token, tokenHash } = await createToken()
    const expiresAt = new Date(Date.now() + INVITATION_LIFETIME_MS).toISOString()
    let rpcData: Record<string, string>
    let organizationId: string

    if (action === "create") {
      organizationId = requireUuid(body.organization_id, "Organización inválida.")
      const email = normalizeEmail(body.email)
      if (typeof body.role !== "string" || !ALLOWED_ROLES.has(body.role)) throw new PublicError("Rol inválido.")
      const { data, error } = await admin.rpc("create_organization_invitation", {
        target_organization_id: organizationId,
        invitation_email: email,
        invitation_role: body.role,
        invitation_token_hash: tokenHash,
        invitation_expires_at: expiresAt,
        actor_user_id: user.id,
      })
      if (error) {
        const publicError = rpcPublicError(error)
        return jsonResponse({ ok: false, error: publicError.message }, publicError.status, origin)
      }
      rpcData = data
    } else {
      const invitationId = requireUuid(body.invitation_id, "Invitación inválida.")
      const { data, error } = await admin.rpc("resend_organization_invitation", {
        target_invitation_id: invitationId,
        invitation_token_hash: tokenHash,
        invitation_expires_at: expiresAt,
        actor_user_id: user.id,
      })
      if (error) {
        const publicError = rpcPublicError(error)
        return jsonResponse({ ok: false, error: publicError.message }, publicError.status, origin)
      }
      rpcData = data
      organizationId = requireUuid(data.organization_id, "Organización inválida.")
    }

    const { data: organization, error: organizationError } = await admin
      .from("organizations")
      .select("id, name")
      .eq("id", organizationId)
      .single()
    if (organizationError || !organization) {
      return jsonResponse({
        ok: false,
        database_updated: true,
        email_sent: false,
        invitation_id: rpcData.id,
        error: "La invitación se guardó, pero no pudimos preparar el correo. Actualiza la lista y usa Reenviar.",
      }, 502, origin)
    }

    const invitationUrl = `${PUBLIC_SITE_ORIGIN}/#/invite?token=${token}`
    try {
      await sendInvitationEmail({
        to: rpcData.email,
        organizationName: organization.name,
        role: rpcData.role,
        invitationUrl,
        expiresAt: rpcData.expires_at,
      })
    } catch (error) {
      const providerDiagnostic = error instanceof EmailProviderError
        ? { provider_status: error.providerStatus, provider_error: error.providerBody }
        : { provider_status: null, provider_error: "email_provider_not_configured_or_unreachable" }
      return jsonResponse({
        ok: false,
        database_updated: true,
        email_sent: false,
        invitation_id: rpcData.id,
        error: "La invitación se guardó, pero el correo no pudo enviarse. Actualiza la lista y usa Reenviar.",
        ...providerDiagnostic,
      }, 502, origin)
    }
    return jsonResponse({ ok: true, invitation_id: rpcData.id, email_sent: true }, 200, origin)
  } catch (error) {
    if (error instanceof PublicError) {
      return jsonResponse({ ok: false, error: error.message }, error.status, origin)
    }
    return jsonResponse({ ok: false, error: "No fue posible procesar la invitación." }, 500, origin)
  }
})
