import { useNavigate } from 'react-router-dom'

import { useAccessProfile } from '@/features/access/accessContext'
import { useAuth } from '@/features/auth/authContext'

/**
 * Shown when an access row exists but is_active is false.
 */
export function AccessInactivePage() {
  const navigate = useNavigate()
  const { signOut } = useAuth()
  const { normalized } = useAccessProfile()

  const label =
    normalized?.staffDisplayName ||
    normalized?.staffFullName ||
    normalized?.email ||
    'Your account'

  return (
    <div className="flex min-h-dvh flex-col items-center justify-center bg-slate-50 px-4">
      <div className="max-w-md rounded-xl border border-amber-200 bg-amber-50 p-8 text-center shadow-sm">
        <h1 className="text-lg font-semibold text-amber-950">Access inactive</h1>
        <p className="mt-2 text-sm text-amber-900">
          Payroll access for <span className="font-medium">{label}</span> is
          currently inactive. Contact a salon administrator to restore access.
        </p>
        <button
          type="button"
          className="mt-6 w-full rounded-md border border-amber-300 bg-white px-3 py-2 text-sm font-medium text-amber-950 hover:bg-amber-100"
          onClick={async () => {
            await signOut()
            navigate('/login', { replace: true })
          }}
        >
          Sign out
        </button>
      </div>
    </div>
  )
}
