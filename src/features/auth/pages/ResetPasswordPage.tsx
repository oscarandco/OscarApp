import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'

import { requireSupabaseClient } from '@/lib/supabase'

/**
 * Landing page for the Supabase password-reset email link.
 *
 * Flow:
 *  1. Supabase exchanges the `#access_token` / `#refresh_token` pair in
 *     the URL hash for a session automatically via
 *     `onAuthStateChange('PASSWORD_RECOVERY')`. While that hasn't
 *     fired we render a neutral "Preparing password reset…" state.
 *  2. Once we are in recovery mode, we show a single-field form and
 *     call `auth.updateUser({ password })`.
 *  3. On success we sign the user out (so they are forced to log in
 *     with the new password) and redirect to `/login`.
 *
 * The page deliberately does NOT require the user to already be signed
 * in — the recovery token grants a temporary session just for this
 * screen.
 */
export function ResetPasswordPage() {
  const navigate = useNavigate()
  const [recoveryReady, setRecoveryReady] = useState(false)
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState(false)

  useEffect(() => {
    const client = requireSupabaseClient()

    // If the user is already mid-recovery (e.g. they refreshed this
    // page after Supabase processed the hash), surface the form
    // immediately instead of getting stuck on the spinner.
    void client.auth.getSession().then(({ data }) => {
      if (data.session) setRecoveryReady(true)
    })

    const {
      data: { subscription },
    } = client.auth.onAuthStateChange((event) => {
      if (event === 'PASSWORD_RECOVERY' || event === 'SIGNED_IN') {
        setRecoveryReady(true)
      }
    })

    return () => {
      subscription.unsubscribe()
    }
  }, [])

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    if (password.length < 8) {
      setError('Password must be at least 8 characters.')
      return
    }
    if (password !== confirm) {
      setError('Passwords do not match.')
      return
    }
    setSubmitting(true)
    const client = requireSupabaseClient()
    const { error: updateErr } = await client.auth.updateUser({ password })
    setSubmitting(false)
    if (updateErr) {
      setError(updateErr.message)
      return
    }
    setSuccess(true)
    // Force a fresh sign-in with the new password.
    await client.auth.signOut()
    setTimeout(() => {
      navigate('/login', { replace: true })
    }, 1500)
  }

  return (
    <div className="flex min-h-dvh flex-col items-center justify-center bg-slate-50 px-4 py-12">
      <div className="w-full max-w-sm rounded-xl border border-slate-200 bg-white p-8 shadow-sm">
        <h1 className="text-center text-xl font-semibold text-slate-900">
          Reset password
        </h1>
        <p className="mt-1 text-center text-sm text-slate-600">
          Choose a new password for your account.
        </p>

        {!recoveryReady ? (
          <p className="mt-6 text-center text-sm text-slate-600">
            Preparing password reset…
          </p>
        ) : success ? (
          <p
            className="mt-6 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-center text-sm text-emerald-800"
            role="status"
          >
            Password updated. Redirecting to sign-in…
          </p>
        ) : (
          <>
            {error ? (
              <p
                className="mt-4 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800"
                role="alert"
              >
                {error}
              </p>
            ) : null}

            <form className="mt-6 space-y-4" onSubmit={(e) => void onSubmit(e)}>
              <div>
                <label
                  htmlFor="new-password"
                  className="block text-sm font-medium text-slate-700"
                >
                  New password
                </label>
                <input
                  id="new-password"
                  name="new-password"
                  type="password"
                  autoComplete="new-password"
                  required
                  minLength={8}
                  value={password}
                  onChange={(e) => setPassword(e.target.value)}
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                />
              </div>
              <div>
                <label
                  htmlFor="confirm-password"
                  className="block text-sm font-medium text-slate-700"
                >
                  Confirm password
                </label>
                <input
                  id="confirm-password"
                  name="confirm-password"
                  type="password"
                  autoComplete="new-password"
                  required
                  minLength={8}
                  value={confirm}
                  onChange={(e) => setConfirm(e.target.value)}
                  className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                />
              </div>
              <button
                type="submit"
                disabled={submitting}
                className="w-full rounded-md bg-violet-600 px-3 py-2 text-sm font-semibold text-white shadow hover:bg-violet-700 disabled:opacity-60"
              >
                {submitting ? 'Updating…' : 'Update password'}
              </button>
            </form>
          </>
        )}
      </div>
    </div>
  )
}
