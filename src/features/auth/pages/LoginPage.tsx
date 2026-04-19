import { useState } from 'react'
import { Navigate, useLocation, useNavigate } from 'react-router-dom'

import logoUrl from '@/assets/logo.png'
import { ErrorState } from '@/components/feedback/ErrorState'
import { useAuth } from '@/features/auth/authContext'
import { requireSupabaseClient } from '@/lib/supabase'

export function LoginPage() {
  const navigate = useNavigate()
  const location = useLocation()
  const { user, loading, signInWithPassword } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<Error | null>(null)
  const [submitting, setSubmitting] = useState(false)

  // Self-service password reset (Forgot password?) state. Kept separate
  // from the sign-in error so either flow's feedback stays on-screen
  // without clobbering the other.
  const [forgotPending, setForgotPending] = useState(false)
  const [forgotMessage, setForgotMessage] = useState<string | null>(null)
  const [forgotError, setForgotError] = useState<string | null>(null)

  // Default post-login landing is Guest Quote — the page stylists use
  // most often. If the user hit a protected URL while signed-out and
  // was bounced to login, `location.state.from.pathname` preserves
  // that intent and we send them back there instead.
  const from =
    (location.state as { from?: { pathname?: string } } | null)?.from
      ?.pathname ?? '/app/guest-quote'

  if (!loading && user) {
    return <Navigate to={from} replace />
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
    setForgotMessage(null)
    setForgotError(null)
    setSubmitting(true)
    const { error: signError } = await signInWithPassword(
      email.trim(),
      password,
    )
    setSubmitting(false)
    if (signError) {
      setError(signError)
      return
    }
    navigate(from, { replace: true })
  }

  async function onForgotPassword() {
    setError(null)
    setForgotMessage(null)
    setForgotError(null)
    const trimmed = email.trim()
    if (!trimmed) {
      setForgotError('Enter your email above first.')
      return
    }
    setForgotPending(true)
    try {
      const client = requireSupabaseClient()
      // Sending the user back to `/reset-password` on the current origin
      // means this works in local dev, Vercel preview, and production
      // without hardcoding a URL. In production this resolves to the
      // live domain (e.g. `https://oscar-app-wine.vercel.app/reset-password`).
      const redirectTo = `${window.location.origin}/reset-password`
      const { error: resetError } = await client.auth.resetPasswordForEmail(
        trimmed,
        { redirectTo },
      )
      if (resetError) {
        setForgotError(
          resetError.message ||
            'Could not send a reset link. Please try again.',
        )
        return
      }
      setForgotMessage(
        'If that email exists, we’ve sent a password reset link.',
      )
    } catch (err) {
      setForgotError(
        err instanceof Error
          ? err.message
          : 'Could not send a reset link. Please try again.',
      )
    } finally {
      setForgotPending(false)
    }
  }

  if (loading) {
    return (
      <div className="flex min-h-dvh items-center justify-center bg-slate-50 px-4">
        <p className="text-sm text-slate-600">Checking session…</p>
      </div>
    )
  }

  return (
    <div className="flex min-h-dvh flex-col items-center justify-center bg-slate-50 px-4 py-12">
      <div className="w-full max-w-sm rounded-xl border border-slate-200 bg-white p-8 shadow-sm">
        <div className="flex justify-center">
          <img
            src={logoUrl}
            alt="Oscar & Co."
            className="h-9 w-auto select-none"
          />
        </div>
        <h1 className="mt-5 text-center text-xl font-semibold text-slate-900">
          Sign in
        </h1>
        <p className="mt-1 text-center text-sm text-slate-600">
          Staff App
        </p>

        {error ? (
          <div className="mt-4">
            <ErrorState title="Sign-in failed" error={error} />
          </div>
        ) : null}

        {forgotMessage ? (
          <div
            className="mt-4 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-800"
            role="status"
            data-testid="login-forgot-success"
          >
            {forgotMessage}
          </div>
        ) : null}

        {forgotError ? (
          <div
            className="mt-4 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-800"
            role="alert"
            data-testid="login-forgot-error"
          >
            {forgotError}
          </div>
        ) : null}

        <form className="mt-6 space-y-4" onSubmit={(e) => void onSubmit(e)}>
          <div>
            <label
              htmlFor="email"
              className="block text-sm font-medium text-slate-700"
            >
              Email
            </label>
            <input
              id="email"
              name="email"
              type="email"
              autoComplete="email"
              required
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
            />
          </div>
          <div>
            <div className="flex items-center justify-between">
              <label
                htmlFor="password"
                className="block text-sm font-medium text-slate-700"
              >
                Password
              </label>
              <button
                type="button"
                onClick={() => void onForgotPassword()}
                disabled={forgotPending}
                className="text-xs font-medium text-violet-700 hover:text-violet-900 disabled:opacity-60"
                data-testid="login-forgot-password-link"
              >
                {forgotPending ? 'Sending…' : 'Forgot password?'}
              </button>
            </div>
            <input
              id="password"
              name="password"
              type="password"
              autoComplete="current-password"
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
            />
          </div>
          <button
            type="submit"
            disabled={submitting}
            className="w-full rounded-md bg-violet-600 px-3 py-2 text-sm font-semibold text-white shadow hover:bg-violet-700 disabled:opacity-60"
          >
            {submitting ? 'Signing in…' : 'Sign in'}
          </button>
        </form>
      </div>
      <p className="mt-8 text-center text-xs text-slate-500">
        Oscar &amp; Co. Staff App
      </p>
    </div>
  )
}
