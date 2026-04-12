import { Link, useNavigate } from 'react-router-dom'

import { useHasElevatedAccess } from '@/features/access/accessContext'
import { useAuth } from '@/features/auth/authContext'

export function TopNav() {
  const navigate = useNavigate()
  const { signOut } = useAuth()
  const elevated = useHasElevatedAccess()

  async function onSignOut() {
    await signOut()
    navigate('/login', { replace: true })
  }

  return (
    <header className="border-b border-slate-200 bg-white">
      <div className="flex h-14 items-center justify-between px-4 lg:px-6">
        <Link to="/app/payroll" className="text-sm font-semibold text-slate-900">
          Oscar & Co — Payroll
        </Link>
        <nav className="flex items-center gap-4 text-sm">
          <Link
            to="/app/payroll"
            className="text-slate-600 hover:text-slate-900"
          >
            My payroll
          </Link>
          {elevated ? (
            <Link
              to="/app/admin"
              className="text-slate-600 hover:text-slate-900"
            >
              Admin
            </Link>
          ) : null}
          <button
            type="button"
            onClick={() => void onSignOut()}
            className="text-slate-600 hover:text-slate-900"
          >
            Sign out
          </button>
        </nav>
      </div>
    </header>
  )
}
