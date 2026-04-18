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
 * On any non-success outcome throws an {@link AdminDeleteUserError}
 * whose `.message` is the server-provided text and `.code` is the
 * structured error code — the UI should render `.message` in a toast
 * and can optionally disable the "Delete" action based on `.code`
 * (e.g. `'still_linked'`).
 */
export async function invokeAdminDeleteUser(userId: string): Promise<void> {
  const client = requireSupabaseClient()
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

  const { data, error } = await client.functions.invoke<DeleteUserResponse>(
    'admin-delete-user',
    {
      body: { user_id: trimmed },
      headers: { Authorization: `Bearer ${accessToken}` },
    },
  )

  if (error) {
    // `functions.invoke` returns the response body on `data` for
    // non-2xx as well, so prefer the structured message when present.
    const code =
      (data && typeof data === 'object' && typeof data.code === 'string'
        ? (data.code as AdminDeleteUserErrorCode)
        : null) ?? null
    const msg =
      (data && typeof data === 'object' && typeof data.error === 'string'
        ? data.error
        : null) ??
      (typeof error === 'object' &&
      error !== null &&
      'message' in error &&
      typeof (error as { message: unknown }).message === 'string'
        ? (error as { message: string }).message
        : String(error))
    throw new AdminDeleteUserError(msg, code)
  }

  if (data && typeof data === 'object' && data.error != null) {
    const code =
      typeof data.code === 'string'
        ? (data.code as AdminDeleteUserErrorCode)
        : null
    throw new AdminDeleteUserError(String(data.error), code)
  }
}
