import { getSupabaseEnvOrNull } from '@/lib/env'
import { requireSupabaseClient } from '@/lib/supabase'

/**
 * Known error codes returned by the `admin-delete-user` Edge Function.
 * Useful when the UI wants to branch on blocked-vs-failed outcomes.
 */
export type AdminDeleteUserErrorCode =
  | 'still_linked'
  | 'self_delete_forbidden'
  | 'user_not_found'
  | 'forbidden_not_admin'
  | 'missing_bearer'
  | 'auth_validation_failed'
  | 'admin_check_error'
  | 'mapping_check_error'
  | 'mapping_cleanup_failed'
  | 'delete_failed'
  | 'invalid_user_id'
  | 'invalid_json'
  | 'server_misconfiguration'
  | 'method_not_allowed'

/**
 * Error thrown by {@link invokeAdminDeleteUser} so callers can preserve
 * the server-side code alongside the human-facing message. The default
 * `Error.message` is already set to the server's message, so this just
 * layers on the structured `code` field.
 */
export class AdminDeleteUserError extends Error {
  readonly code: AdminDeleteUserErrorCode | null
  constructor(message: string, code: AdminDeleteUserErrorCode | null) {
    super(message)
    this.name = 'AdminDeleteUserError'
    this.code = code
  }
}

type DeleteUserResponse = {
  ok?: boolean
  error?: string
  code?: string
}

/**
 * Deletes a Supabase auth user by id via the `admin-delete-user` Edge
 * Function. The function enforces admin access and the safety checks
 * (no active staff mapping, not the caller themselves, user exists).
 *
 * The Edge Function is configured with `verify_jwt = false` and performs
 * its own bearer-token validation, so we MUST send the current session's
 * `Authorization: Bearer <access_token>` explicitly. We bypass
 * `supabase.functions.invoke()` and call the function with `fetch`
 * directly to guarantee the header lands on the request exactly as set.
 *
 * On any non-success outcome throws an {@link AdminDeleteUserError}
 * whose `.message` is the server-provided text and `.code` is the
 * structured error code — the UI should render `.message` in a toast
 * and can optionally disable the "Delete" action based on `.code`
 * (e.g. `'still_linked'`).
 */
export async function invokeAdminDeleteUser(userId: string): Promise<void> {
  const client = requireSupabaseClient()
  const env = getSupabaseEnvOrNull()
  if (!env) {
    throw new AdminDeleteUserError('Supabase is not configured.', null)
  }
  const trimmed = userId.trim()

  const { data: sessionData, error: sessionError } =
    await client.auth.getSession()
  if (sessionError) {
    throw new AdminDeleteUserError(sessionError.message, null)
  }
  const accessToken = sessionData.session?.access_token
  if (!accessToken) {
    throw new AdminDeleteUserError(
      'You must be signed in to delete users. Refresh the page or sign in again.',
      null,
    )
  }

  const url = `${env.url.replace(/\/+$/, '')}/functions/v1/admin-delete-user`

  let response: Response
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        apikey: env.anonKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ user_id: trimmed }),
    })
  } catch (err) {
    throw new AdminDeleteUserError(
      err instanceof Error ? err.message : 'Network error deleting user',
      null,
    )
  }

  let payload: DeleteUserResponse | null = null
  try {
    payload = (await response.json()) as DeleteUserResponse
  } catch {
    payload = null
  }

  if (!response.ok) {
    const code =
      payload && typeof payload.code === 'string'
        ? (payload.code as AdminDeleteUserErrorCode)
        : null
    const msg =
      (payload && typeof payload.error === 'string' ? payload.error : null) ??
      `Delete user failed (HTTP ${response.status})`
    throw new AdminDeleteUserError(msg, code)
  }

  if (payload && payload.error != null) {
    const code =
      typeof payload.code === 'string'
        ? (payload.code as AdminDeleteUserErrorCode)
        : null
    throw new AdminDeleteUserError(String(payload.error), code)
  }
}
