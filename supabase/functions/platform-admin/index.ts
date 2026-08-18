import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  createClient,
  type PostgrestError,
} from "npm:@supabase/supabase-js@2.57.4";

const EXACT_ORIGINS = new Set([
  "https://mxbusinesscard.com",
  "http://127.0.0.1:4173",
  "http://localhost:4173",
]);
const ACTIONS = new Set([
  "list_customers",
  "get_customer",
  "list_card_limit_history",
  "set_contracted_cards",
]);
const SENSITIVE_FIELDS = new Set([
  "actor_user_id",
  "changed_by",
  "user_id",
  "email",
  "role",
  "service_role",
  "service_role_key",
  "supabase_service_role_key",
  "jwt",
  "password",
]);
const UUID_PATTERN =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_REQUEST_BYTES = 8192;
const MAX_INTEGER = 2147483647;
const DEFAULT_PAGE = 1;
const DEFAULT_PAGE_SIZE = 25;
const MAX_PAGE_SIZE = 100;

type JsonObject = Record<string, unknown>;
type Action =
  | "list_customers"
  | "get_customer"
  | "list_card_limit_history"
  | "set_contracted_cards";
type SafeErrorCode =
  | "unauthorized"
  | "forbidden"
  | "invalid_request"
  | "conflict"
  | "not_found"
  | "internal_error";

class RequestError extends Error {
  constructor(
    readonly code: SafeErrorCode,
    message: string,
    readonly status: number,
  ) {
    super(message);
  }
}

function isAllowedOrigin(origin: string | null): origin is string {
  if (!origin) return false;
  try {
    const parsed = new URL(origin);
    return parsed.origin === origin && EXACT_ORIGINS.has(parsed.origin);
  } catch {
    return false;
  }
}

function corsHeaders(origin: string) {
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers":
      "authorization, apikey, x-client-info, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    "Vary": "Origin",
  };
}

function jsonResponse(origin: string, status: number, body: JsonObject) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      ...corsHeaders(origin),
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function errorResponse(origin: string, error: RequestError) {
  return jsonResponse(origin, error.status, {
    ok: false,
    error: { code: error.code, message: error.message },
  });
}

function hasOnlyAllowedKeys(body: JsonObject, allowedKeys: string[]) {
  const allowed = new Set(allowedKeys);
  return Object.keys(body).every((key) => allowed.has(key));
}

function requireUuid(value: unknown, fieldName: string) {
  if (typeof value !== "string" || !UUID_PATTERN.test(value)) {
    throw new RequestError(
      "invalid_request",
      `${fieldName} no es válido.`,
      400,
    );
  }
  return value;
}

function optionalPage(
  value: unknown,
  fallback: number,
  fieldName: string,
  maximum?: number,
) {
  const resolved = value === undefined ? fallback : value;
  if (
    typeof resolved !== "number" ||
    !Number.isSafeInteger(resolved) ||
    resolved < 1 ||
    (maximum !== undefined && resolved > maximum)
  ) {
    throw new RequestError(
      "invalid_request",
      `${fieldName} no es válido.`,
      400,
    );
  }
  return resolved;
}

function requireNonNegativeInteger(value: unknown, fieldName: string) {
  if (
    typeof value !== "number" ||
    !Number.isSafeInteger(value) ||
    value < 0 ||
    value > MAX_INTEGER
  ) {
    throw new RequestError(
      "invalid_request",
      `${fieldName} no es válido.`,
      400,
    );
  }
  return value;
}

function mapDatabaseError(error: PostgrestError) {
  switch (error.code) {
    case "42501":
      return new RequestError(
        "forbidden",
        "No tienes autorización para realizar esta operación.",
        403,
      );
    case "40001":
      return new RequestError(
        "conflict",
        "Los datos cambiaron. Actualiza la información e intenta nuevamente.",
        409,
      );
    case "P0002":
      return new RequestError(
        "not_found",
        "No se encontró el recurso solicitado.",
        404,
      );
    case "22023":
      return new RequestError(
        "invalid_request",
        "La solicitud contiene datos no válidos.",
        400,
      );
    default:
      return new RequestError(
        "internal_error",
        "No fue posible completar la operación.",
        500,
      );
  }
}

Deno.serve(async (request: Request) => {
  const startedAt = performance.now();
  const requestId = crypto.randomUUID();
  const origin = request.headers.get("Origin");
  let actionForLog = "unknown";
  let actorForLog: string | null = null;
  let responseStatus = 500;

  const finish = (response: Response) => {
    responseStatus = response.status;
    console.info("platform_admin_request", {
      request_id: requestId,
      action: actionForLog,
      actor_user_id: actorForLog,
      status: responseStatus,
      duration_ms: Math.round(performance.now() - startedAt),
    });
    return response;
  };

  if (!isAllowedOrigin(origin)) {
    return finish(
      new Response(
        JSON.stringify({
          ok: false,
          error: { code: "forbidden", message: "Origen no autorizado." },
        }),
        {
          status: 403,
          headers: {
            "Content-Type": "application/json; charset=utf-8",
            "Cache-Control": "no-store",
          },
        },
      ),
    );
  }

  if (request.method === "OPTIONS") {
    actionForLog = "preflight";
    return finish(
      new Response(null, { status: 204, headers: corsHeaders(origin) }),
    );
  }

  if (request.method !== "POST") {
    return finish(errorResponse(
      origin,
      new RequestError("invalid_request", "Método no permitido.", 405),
    ));
  }

  const authorization = request.headers.get("Authorization");
  if (!authorization?.toLowerCase().startsWith("bearer ")) {
    return finish(errorResponse(
      origin,
      new RequestError("unauthorized", "Se requiere una sesión válida.", 401),
    ));
  }
  const jwt = authorization.slice(7).trim();
  if (!jwt) {
    return finish(errorResponse(
      origin,
      new RequestError("unauthorized", "Se requiere una sesión válida.", 401),
    ));
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) {
    return finish(errorResponse(
      origin,
      new RequestError(
        "internal_error",
        "Servicio temporalmente no disponible.",
        503,
      ),
    ));
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: userData, error: userError } = await admin.auth.getUser(jwt);
  const user = userData?.user;
  if (userError || !user) {
    return finish(errorResponse(
      origin,
      new RequestError("unauthorized", "La sesión no es válida.", 401),
    ));
  }
  actorForLog = user.id;

  const contentType = request.headers.get("Content-Type") || "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    return finish(errorResponse(
      origin,
      new RequestError("invalid_request", "El contenido debe ser JSON.", 415),
    ));
  }
  const declaredLength = Number(request.headers.get("Content-Length") || "0");
  if (!Number.isFinite(declaredLength) || declaredLength > MAX_REQUEST_BYTES) {
    return finish(errorResponse(
      origin,
      new RequestError(
        "invalid_request",
        "La solicitud es demasiado grande.",
        413,
      ),
    ));
  }

  let body: JsonObject;
  try {
    const rawBody = await request.text();
    if (new TextEncoder().encode(rawBody).byteLength > MAX_REQUEST_BYTES) {
      throw new RequestError(
        "invalid_request",
        "La solicitud es demasiado grande.",
        413,
      );
    }
    const parsed = JSON.parse(rawBody);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      throw new RequestError(
        "invalid_request",
        "La solicitud no es válida.",
        400,
      );
    }
    body = parsed as JsonObject;
  } catch (error) {
    const publicError = error instanceof RequestError
      ? error
      : new RequestError("invalid_request", "La solicitud no es válida.", 400);
    return finish(errorResponse(origin, publicError));
  }

  for (const key of SENSITIVE_FIELDS) {
    if (Object.hasOwn(body, key)) {
      return finish(errorResponse(
        origin,
        new RequestError(
          "invalid_request",
          "La solicitud contiene campos no permitidos.",
          400,
        ),
      ));
    }
  }

  const action = body.action;
  if (typeof action !== "string" || !ACTIONS.has(action)) {
    return finish(errorResponse(
      origin,
      new RequestError("invalid_request", "La acción no es válida.", 400),
    ));
  }
  actionForLog = action;

  const allowedKeys: Record<Action, string[]> = {
    list_customers: ["action", "search_text", "page", "page_size"],
    get_customer: ["action", "organization_id"],
    list_card_limit_history: ["action", "subscription_id", "page", "page_size"],
    set_contracted_cards: [
      "action",
      "subscription_id",
      "expected_contracted_cards",
      "new_contracted_cards",
      "change_reason",
    ],
  };
  if (!hasOnlyAllowedKeys(body, allowedKeys[action as Action])) {
    return finish(errorResponse(
      origin,
      new RequestError(
        "invalid_request",
        "La solicitud contiene campos no permitidos.",
        400,
      ),
    ));
  }

  // private.platform_admin_role() permanece fuera del Data API. Esta RPC mínima
  // ejecuta ese helper internamente y actúa como comprobación previa fail-closed.
  const { error: authorizationError } = await admin.rpc(
    "list_platform_customers",
    {
      actor_user_id: user.id,
      search_text: null,
      page: 1,
      page_size: 1,
    },
  );
  if (authorizationError) {
    const mapped = mapDatabaseError(authorizationError);
    const publicError = mapped.code === "forbidden" ? mapped : new RequestError(
      "internal_error",
      "No fue posible validar la autorización.",
      500,
    );
    return finish(errorResponse(origin, publicError));
  }

  try {
    let rpcName: string;
    let rpcArguments: JsonObject;

    if (action === "list_customers") {
      if (
        body.search_text !== undefined && typeof body.search_text !== "string"
      ) {
        throw new RequestError(
          "invalid_request",
          "La búsqueda no es válida.",
          400,
        );
      }
      const searchText = typeof body.search_text === "string"
        ? body.search_text.trim()
        : "";
      if (searchText.length > 160) {
        throw new RequestError(
          "invalid_request",
          "La búsqueda debe tener máximo 160 caracteres.",
          400,
        );
      }
      rpcName = "list_platform_customers";
      rpcArguments = {
        actor_user_id: user.id,
        search_text: searchText || null,
        page: optionalPage(body.page, DEFAULT_PAGE, "page"),
        page_size: optionalPage(
          body.page_size,
          DEFAULT_PAGE_SIZE,
          "page_size",
          MAX_PAGE_SIZE,
        ),
      };
    } else if (action === "get_customer") {
      rpcName = "get_platform_customer";
      rpcArguments = {
        actor_user_id: user.id,
        target_organization_id: requireUuid(
          body.organization_id,
          "organization_id",
        ),
      };
    } else if (action === "list_card_limit_history") {
      rpcName = "list_platform_card_limit_history";
      rpcArguments = {
        actor_user_id: user.id,
        target_subscription_id: requireUuid(
          body.subscription_id,
          "subscription_id",
        ),
        page: optionalPage(body.page, DEFAULT_PAGE, "page"),
        page_size: optionalPage(
          body.page_size,
          DEFAULT_PAGE_SIZE,
          "page_size",
          MAX_PAGE_SIZE,
        ),
      };
    } else {
      if (typeof body.change_reason !== "string") {
        throw new RequestError(
          "invalid_request",
          "El motivo es obligatorio.",
          400,
        );
      }
      const changeReason = body.change_reason.trim();
      if (!changeReason || changeReason.length > 500) {
        throw new RequestError(
          "invalid_request",
          "El motivo es obligatorio y debe tener máximo 500 caracteres.",
          400,
        );
      }
      rpcName = "set_subscription_contracted_cards_by_admin";
      rpcArguments = {
        actor_user_id: user.id,
        target_subscription_id: requireUuid(
          body.subscription_id,
          "subscription_id",
        ),
        expected_contracted_cards: requireNonNegativeInteger(
          body.expected_contracted_cards,
          "expected_contracted_cards",
        ),
        new_contracted_cards: requireNonNegativeInteger(
          body.new_contracted_cards,
          "new_contracted_cards",
        ),
        change_reason: changeReason,
      };
    }

    const { data, error } = await admin.rpc(rpcName, rpcArguments);
    if (error) throw mapDatabaseError(error);
    return finish(jsonResponse(origin, 200, { ok: true, data }));
  } catch (error) {
    const publicError = error instanceof RequestError
      ? error
      : new RequestError(
        "internal_error",
        "No fue posible completar la operación.",
        500,
      );
    return finish(errorResponse(origin, publicError));
  }
});
