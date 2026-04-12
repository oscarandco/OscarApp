import { useState } from 'react'
import { Navigate, useLocation, useNavigate } from 'react-router-dom'

import { ErrorState } from '@/components/feedback/ErrorState'
import { useAuth } from '@/features/auth/authContext'

export function LoginPage() {
  const navigate = useNavigate()
  const location = useLocation()
  const { user, loading, signInWithPassword } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<Error | null>(null)
  const [submitting, setSubmitting] = useState(false)

  const from =
    (location.state as { from?: { pathname?: string } } | null)?.from
      ?.pathname ?? '/app/payroll'

  if (!loading && user) {
    return <Navigate to={from} replace />
  }

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault()
    setError(null)
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
        <h1 className="text-center text-xl font-semibold text-slate-900">
          Sign in
        </h1>
        <p className="mt-1 text-center text-sm text-slate-600">
          Salon payroll & commission
        </p>

        {error ? (
          <div className="mt-4">
            <ErrorState title="Sign-in failed" error={error} />
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
            <label
              htmlFor="password"
              className="block text-sm font-medium text-slate-700"
            >
              Password
            </label>
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
        Salon commission & payroll reporting.
      </p>
    </div>
  )
}
