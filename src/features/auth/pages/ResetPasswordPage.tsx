import { useEffect, useRef, useState } from 'react'
import { useNavigate } from 'react-router-dom'

import { requireSupabaseClient } from '@/lib/supabase'

type InviteFlow = 'invite' | 'recovery' | 'unknown'

function readPasswordSetupFlowFromUrl(): InviteFlow {
  if (typeof window === 'undefined') return 'unknown'
  const h = window.location.hash.toLowerCase()
  if (h.includes('type=signup')) return 'invite'
  if (h.includes('type=recovery')) return 'recovery'
  return 'unknown'
}

/**
 * Password setup (invite) and password reset (forgot password).
 *
 * Supabase `detectSessionInUrl` exchanges `#access_token` / `?code=` for a
 * session. We listen for `INITIAL_SESSION`, `SIGNED_IN`, and `PASSWORD_RECOVERY`
 * so the form appears reliably for invites (which may not emit PASSWORD_RECOVERY).
 *
 * `/` and `/login` forward auth callbacks here via `authCallbackUrl` so tokens
 * are not dropped by redirects into `/app`.
 */
export function ResetPasswordPage() {
  const navigate = useNavigate()
  const flowRef = useRef<InviteFlow>(readPasswordSetupFlowFromUrl())
  const [recoveryReady, setRecoveryReady] = useState(false)
  const [password, setPassword] = useState('')
  const [confirm, setConfirm] = useState('')
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState(false)

  const isInvite = flowRef.current === 'invite'
  const title = isInvite ? 'Set up your account' : 'Reset password'
  const subtitle = isInvite
    ? 'Choose a password to finish setting up your Oscar & Co Staff App account.'
    : 'Choose a new password for your account.'

  useEffect(() => {
    const client = requireSupabaseClient()

    void client.auth.getSession().then(({ data }) => {
      if (data.session) setRecoveryReady(true)
    })

    const {
      data: { subscription },
    } = client.auth.onAuthStateChange((event, session) => {
      if (event === 'PASSWORD_RECOVERY') {
        setRecoveryReady(true)
        return
      }
      if (event === 'SIGNED_IN' && session) {
        setRecoveryReady(true)
        return
      }
      if (event === 'INITIAL_SESSION' && session) {
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

    const flow = flowRef.current
    if (flow === 'invite') {
      setTimeout(() => {
        navigate('/app/my-sales', { replace: true })
      }, 900)
      return
    }

    await client.auth.signOut()
    setTimeout(() => {
      navigate('/login', { replace: true })
    }, 1500)
  }

  return (
    <div className="flex min-h-dvh flex-col items-center justify-center bg-slate-50 px-4 py-12">
      <div className="w-full max-w-sm rounded-xl border border-slate-200 bg-white p-8 shadow-sm">
        <h1 className="text-center text-xl font-semibold text-slate-900">{title}</h1>
        <p className="mt-1 text-center text-sm text-slate-600">{subtitle}</p>

        {!recoveryReady ? (
          <p className="mt-6 text-center text-sm text-slate-600">
            Preparing secure session…
          </p>
        ) : success ? (
          <p
            className="mt-6 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-center text-sm text-emerald-800"
            role="status"
          >
            {isInvite
              ? 'Password saved. Taking you to My Sales…'
              : 'Password updated. Redirecting to sign-in…'}
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
                {submitting ? 'Saving…' : isInvite ? 'Save password' : 'Update password'}
              </button>
            </form>
          </>
        )}
      </div>
    </div>
  )
}
