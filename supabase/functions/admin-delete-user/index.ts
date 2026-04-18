/**
 * Delete a Supabase auth user on behalf of an app admin, but only when it
 * is safe to do so. Intended for mistaken invites, duplicate accounts, or
 * unused accounts — not as a general off-boarding tool. For real
 * off-boarding use Edit + Deactivate instead.
 *
 * Safety checks (fail-closed):
 *   1. Caller must be authenticated and pass
 *      `caller_can_manage_access_mappings()` (app admin).
 *   2. Caller may not delete themselves (prevents lock-out).
 *   3. Target auth user must exist.
 *   4. Target user must have NO active `staff_member_user_access` rows.
 *      An active mapping is treated as "still linked to a staff mapping"
 *      and the delete is blocked with a clear message.
 *
 * If all checks pass:
 *   - Any remaining (inactive) `staff_member_user_access` rows for that
 *     user are removed so FKs don't block the delete and there is no
 *     orphan mapping left behind.
 *   - The auth user is deleted via the admin API.
 *
 * Body: { user_id: string }
 * Success: { ok: true, code: "user_deleted" }
 * Failure:
 *   - { error, code: "still_linked" }          (400)  ← blocked
 *   - { error, code: "self_delete_forbidden" } (400)
 *   - { error, code: "user_not_found" }        (404)
 *   - other codes for validation / infra errors
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

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

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
    console.error("admin-delete-user: missing Supabase env")
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

  const callerId = userData.user.id

  const { data: canManage, error: rpcErr } = await userClient.rpc(
    "caller_can_manage_access_mappings",
  )

  if (rpcErr) {
    console.error(
      "admin-delete-user: caller_can_manage_access_mappings",
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

  let body: { user_id?: unknown }
  try {
    body = await req.json()
  } catch {
    return json({ error: "Invalid JSON body", code: "invalid_json" }, 400)
  }

  const targetUserId =
    typeof body.user_id === "string" ? body.user_id.trim() : ""
  if (!targetUserId || !UUID_RE.test(targetUserId)) {
    return json(
      { error: "A valid target user_id is required", code: "invalid_user_id" },
      400,
    )
  }

  // Safety check 2: never delete yourself via this surface. Caller should
  // remove their own account through a different flow so we don't risk
  // accidental admin lock-outs.
  if (targetUserId === callerId) {
    return json(
      {
        error:
          "You cannot delete your own account from Access Management. Ask another admin.",
        code: "self_delete_forbidden",
      },
      400,
    )
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  })

  // Safety check 3: target auth user exists.
  const { data: targetRes, error: getTargetErr } =
    await admin.auth.admin.getUserById(targetUserId)
  if (getTargetErr || !targetRes?.user) {
    return json(
      {
        error: "User could not be found. They may already be deleted.",
        code: "user_not_found",
      },
      404,
    )
  }

  // Safety check 4: block if the user still has any ACTIVE mapping.
  // Inactive mappings are allowed — they are just historical rows and will
  // be cleaned up below to keep app data consistent.
  const { data: activeRows, error: activeErr } = await admin
    .from("staff_member_user_access")
    .select("id")
    .eq("user_id", targetUserId)
    .eq("is_active", true)
    .limit(1)

  if (activeErr) {
    console.error("admin-delete-user: active mapping lookup", activeErr)
    return json(
      {
        error: "Could not verify access mappings for this user",
        code: "mapping_check_error",
      },
      500,
    )
  }

  if (activeRows && activeRows.length > 0) {
    return json(
      {
        error:
          "User is still linked to a staff mapping. Deactivate or unlink first.",
        code: "still_linked",
      },
      400,
    )
  }

  // Controlled local cleanup: remove any INACTIVE mapping rows so we don't
  // leave orphan `staff_member_user_access` rows pointing at a
  // now-deleted auth user. Only the rows for this target user are touched.
  const { error: delMappingsErr } = await admin
    .from("staff_member_user_access")
    .delete()
    .eq("user_id", targetUserId)

  if (delMappingsErr) {
    console.error("admin-delete-user: mapping cleanup", delMappingsErr)
    return json(
      {
        error: "Could not clean up access mapping history for this user",
        code: "mapping_cleanup_failed",
      },
      500,
    )
  }

  const { error: deleteErr } = await admin.auth.admin.deleteUser(targetUserId)
  if (deleteErr) {
    console.error("admin-delete-user: deleteUser", deleteErr)
    return json(
      {
        error: deleteErr.message || "Failed to delete user",
        code: "delete_failed",
      },
      500,
    )
  }

  return json({ ok: true, code: "user_deleted" })
})
