/**
 * Invite a user by email (Supabase Auth invite). Only callers with app admin access
 * (staff_member_user_access.access_role in admin, superadmin) may invoke.
 *
 * Gateway verify_jwt is off (see config.toml); this handler validates JWT via getUser(accessToken)
 * and caller_can_manage_access_mappings().
 *
 * Invite email link: set INVITE_REDIRECT_TO to your full URL (e.g. https://…/reset-password
 * or https://…/setup-account), or set APP_SITE_URL to the site origin so we default to
 * {APP_SITE_URL}/reset-password. Add the same URL under Supabase Auth → Redirect URLs.
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
    console.error("invite-access-user: missing Supabase env")
    return json({ error: "Server misconfiguration", code: "server_misconfiguration" }, 500)
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
    console.error("invite-access-user: caller_can_manage_access_mappings", rpcErr)
    return json(
      {
        error: "Could not verify admin access",
        code: "admin_check_error",
      },
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

  const inviteRedirectExplicit = Deno.env.get("INVITE_REDIRECT_TO")?.trim()
  const appSite = Deno.env.get("APP_SITE_URL")?.trim().replace(/\/$/, "")
  const redirectTo =
    inviteRedirectExplicit && inviteRedirectExplicit.length > 0
      ? inviteRedirectExplicit
      : appSite && appSite.length > 0
        ? `${appSite}/reset-password`
        : undefined

  const { error: inviteErr } = await admin.auth.admin.inviteUserByEmail(email, {
    ...(redirectTo ? { redirectTo } : {}),
  })

  if (inviteErr) {
    return json(
      {
        error: inviteErr.message || "Failed to send invite",
        code: "invite_failed",
      },
      500,
    )
  }

  return json({ ok: true, code: "invited" })
})
