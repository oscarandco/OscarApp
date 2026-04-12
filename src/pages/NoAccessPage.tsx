import { useNavigate } from 'react-router-dom'

import { useAuth } from '@/features/auth/authContext'

/**
 * Shown when get_my_access_profile returns no row for the signed-in user.
 */
export function NoAccessPage() {
  const navigate = useNavigate()
  const { signOut, user } = useAuth()

  return (
    <div className="flex min-h-dvh flex-col items-center justify-center bg-slate-50 px-4">
      <div className="max-w-md rounded-xl border border-slate-200 bg-white p-8 text-center shadow-sm">
        <h1 className="text-lg font-semibold text-slate-900">No access</h1>
        <p className="mt-2 text-sm text-slate-600">
          Your account is signed in, but there is no payroll access configured for
          you yet. Contact a salon administrator if this is unexpected.
        </p>
        {user?.email ? (
          <p className="mt-4 font-mono text-xs text-slate-500">{user.email}</p>
        ) : null}
        <button
          type="button"
          className="mt-6 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 hover:bg-slate-50"
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
