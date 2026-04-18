import { Link, useNavigate } from 'react-router-dom'

import logoUrl from '@/assets/logo.png'
import { useHasElevatedAccess } from '@/features/access/accessContext'
import { useAuth } from '@/features/auth/authContext'

export function TopNav({
  onOpenMobileNav,
}: {
  /**
   * Click handler for the mobile hamburger. Rendered only below the
   * `lg` breakpoint (the persistent sidebar takes over above `lg`).
   * Omitting this prop hides the button entirely.
   */
  onOpenMobileNav?: () => void
} = {}) {
  const navigate = useNavigate()
  const { signOut } = useAuth()
  const elevated = useHasElevatedAccess()

  async function onSignOut() {
    await signOut()
    navigate('/login', { replace: true })
  }

  return (
    <header className="border-b border-slate-200 bg-white">
      <div className="flex h-14 items-center justify-between gap-2 px-3 sm:px-4 lg:px-6">
        <div className="flex min-w-0 items-center gap-1.5">
          {onOpenMobileNav ? (
            <button
              type="button"
              onClick={onOpenMobileNav}
              aria-label="Open menu"
              className="-ml-1 inline-flex h-9 w-9 items-center justify-center rounded-md text-slate-700 hover:bg-slate-100 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 lg:hidden"
              data-testid="top-nav-open-menu"
            >
              <svg
                aria-hidden="true"
                viewBox="0 0 24 24"
                className="h-5 w-5"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
              >
                <line x1="4" y1="6" x2="20" y2="6" />
                <line x1="4" y1="12" x2="20" y2="12" />
                <line x1="4" y1="18" x2="20" y2="18" />
              </svg>
            </button>
          ) : null}
          <Link
            to="/app/my-sales"
            className="flex min-w-0 items-center gap-2.5 text-sm font-semibold text-slate-900"
          >
            <img
              src={logoUrl}
              alt=""
              aria-hidden="true"
              className="h-6 w-auto shrink-0 select-none"
            />
            <span className="hidden sm:inline"> </span>
          </Link>
        </div>
        <nav className="flex items-center gap-3 text-sm sm:gap-4">
          <Link
            to="/app/my-sales"
            className="hidden text-slate-600 hover:text-slate-900 sm:inline"
          >
            My sales
          </Link>
          {elevated ? (
            <Link
              to="/app/admin"
              className="hidden text-slate-600 hover:text-slate-900 sm:inline"
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
