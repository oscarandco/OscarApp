import { requireSupabaseClient } from '@/lib/supabase'

/**
 * Sends a Supabase password-reset email to the given address via the
 * `admin-send-password-reset` Edge Function (service role on server
 * only). Caller must be an app admin; enforced in-function.
 *
 * Throws on any non-success response so callers can surface the
 * message directly in a toast / error state.
 */
export async function invokeAdminSendPasswordReset(
  email: string,
): Promise<void> {
  const client = requireSupabaseClient()
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

  const { data, error } = await client.functions.invoke(
    'admin-send-password-reset',
    {
      body: { email: trimmed },
      headers: { Authorization: `Bearer ${accessToken}` },
    },
  )
  if (error) {
    const msg =
      typeof error === 'object' &&
      error !== null &&
      'message' in error &&
      typeof (error as { message: unknown }).message === 'string'
        ? (error as { message: string }).message
        : String(error)
    throw new Error(msg)
  }
  if (
    data &&
    typeof data === 'object' &&
    'error' in data &&
    (data as { error?: unknown }).error != null
  ) {
    throw new Error(String((data as { error: unknown }).error))
  }
}
