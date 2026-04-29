import { useLayoutEffect } from 'react'
import { useNavigate } from 'react-router-dom'

import { buildResetPasswordPath, hasSupabaseAuthCallbackInUrl } from '@/lib/authCallbackUrl'

/**
 * `/` — send normal visitors to Guest Quote, but if Supabase auth tokens are in
 * the URL (invite / reset / PKCE), forward to `/reset-password` first so the
 * hash or `code` is not lost.
 */
export function HomeRoute() {
  const navigate = useNavigate()

  useLayoutEffect(() => {
    if (hasSupabaseAuthCallbackInUrl()) {
      navigate(buildResetPasswordPath(), { replace: true })
      return
    }
    navigate('/app/guest-quote', { replace: true })
  }, [navigate])

  return (
    <div className="flex min-h-dvh items-center justify-center bg-slate-50 px-4">
      <p className="text-sm text-slate-600">Opening…</p>
    </div>
  )
}
