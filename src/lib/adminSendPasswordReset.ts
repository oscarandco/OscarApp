import { getSupabaseEnvOrNull } from '@/lib/env'
import { requireSupabaseClient } from '@/lib/supabase'

/**
 * Sends a Supabase password-reset email to the given address via the
 * `admin-send-password-reset` Edge Function (service role on server
 * only). Caller must be an app admin; enforced in-function.
 *
 * The Edge Function is configured with `verify_jwt = false` and performs
 * its own bearer-token validation, so we MUST send the current session's
 * `Authorization: Bearer <access_token>` explicitly. We bypass
 * `supabase.functions.invoke()` and call the function with `fetch`
 * directly to guarantee the header lands on the request exactly as set
 * (the JS client can otherwise swap in the anon key in some cases).
 *
 * Throws on any non-success response so callers can surface the
 * message directly in a toast / error state.
 */
export async function invokeAdminSendPasswordReset(
  email: string,
): Promise<void> {
  const client = requireSupabaseClient()
  const env = getSupabaseEnvOrNull()
  if (!env) {
    throw new Error('Supabase is not configured.')
  }
  const trimmed = email.trim()

  const { data: sessionData, error: sessionError } =
    await client.auth.getSession()
  if (sessionError) {
    throw new Error(sessionError.message)
  }
  const accessToken = sessionData.session?.access_token
  if (!accessToken) {
    throw new Error(
      'You must be signed in to send a password reset. Refresh the page or sign in again.',
    )
  }

  const url = `${env.url.replace(/\/+$/, '')}/functions/v1/admin-send-password-reset`

  let response: Response
  try {
    response = await fetch(url, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${accessToken}`,
        apikey: env.anonKey,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ email: trimmed }),
    })
  } catch (err) {
    throw new Error(
      err instanceof Error ? err.message : 'Network error sending password reset',
    )
  }

  let payload: unknown = null
  try {
    payload = await response.json()
  } catch {
    payload = null
  }

  if (!response.ok) {
    const msg =
      payload &&
      typeof payload === 'object' &&
      'error' in payload &&
      typeof (payload as { error?: unknown }).error === 'string'
        ? (payload as { error: string }).error
        : `Password reset failed (HTTP ${response.status})`
    throw new Error(msg)
  }

  if (
    payload &&
    typeof payload === 'object' &&
    'error' in payload &&
    (payload as { error?: unknown }).error != null
  ) {
    throw new Error(String((payload as { error: unknown }).error))
  }
}
