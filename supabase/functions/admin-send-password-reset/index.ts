/**
 * Send a password-reset email on behalf of an app admin. Only callers with
 * app admin access (staff_member_user_access.access_role in admin,
 * superadmin) may invoke.
 *
 * Gateway verify_jwt is off (see config.toml); this handler validates the
 * JWT via `getUser(accessToken)` and then calls
 * `caller_can_manage_access_mappings()` to confirm elevated access, exactly
 * like `invite-access-user`.
 *
 * Body: { email: string }
 * Response: { ok: true, code: "reset_sent" } | { error, code }
 */
import "jsr:@supabase/functions-js/edge-runtime.d.ts"

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.49.8"

const corsHeaders: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders })
  }

  if (req.method !== "POST") {
    return json({ error: "Method not allowed", code: "method_not_allowed" }, 405)
  }

  const authHeaderRaw = req.headers.get("Authorization")
  const bearerMatch = authHeaderRaw?.trim().match(/^Bearer\s+(.+)$/i)
  const accessToken = bearerMatch?.[1]?.trim() ?? ""

  if (!accessToken) {
    return json(
      {
        error: "Missing or invalid bearer token in Authorization header",
        code: "missing_bearer",
      },
      401,
    )
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL")
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY")
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
  if (!supabaseUrl || !anonKey || !serviceKey) {
    console.error("admin-send-password-reset: missing Supabase env")
    return json(
      { error: "Server misconfiguration", code: "server_misconfiguration" },
      500,
    )
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${accessToken}` } },
  })

  const { data: userData, error: getUserErr } =
    await userClient.auth.getUser(accessToken)

  if (getUserErr || !userData.user) {
    return json(
      {
        error: "Session could not be validated",
        code: "auth_validation_failed",
      },
      401,
    )
  }

  const { data: canManage, error: rpcErr } = await userClient.rpc(
    "caller_can_manage_access_mappings",
  )

  if (rpcErr) {
    console.error(
      "admin-send-password-reset: caller_can_manage_access_mappings",
      rpcErr,
    )
    return json(
      { error: "Could not verify admin access", code: "admin_check_error" },
      500,
    )
  }

  if (canManage !== true) {
    return json(
      { error: "Admin access required", code: "forbidden_not_admin" },
      403,
    )
  }

  let body: { email?: unknown }
  try {
    body = await req.json()
  } catch {
    return json({ error: "Invalid JSON body", code: "invalid_json" }, 400)
  }

  const email =
    typeof body.email === "string" ? body.email.trim().toLowerCase() : ""
  if (!email || !EMAIL_RE.test(email)) {
    return json(
      { error: "A valid email address is required", code: "invalid_email" },
      400,
    )
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  // Redirect target: prefer an explicit env (so staging/prod can diverge),
  // fall back to the invite redirect so we reuse one configured URL, then
  // to `/reset-password` on the same origin if we can't infer anything.
  const redirectTo =
    Deno.env.get("PASSWORD_RESET_REDIRECT_TO") ??
    Deno.env.get("INVITE_REDIRECT_TO") ??
    undefined

  const { error: resetErr } = await admin.auth.resetPasswordForEmail(email, {
    ...(redirectTo ? { redirectTo } : {}),
  })

  if (resetErr) {
    console.error("admin-send-password-reset: resetPasswordForEmail", resetErr)
    return json(
      {
        error: resetErr.message || "Failed to send password reset",
        code: "reset_failed",
      },
      500,
    )
  }

  return json({ ok: true, code: "reset_sent" })
})
