import { Link, useNavigate } from 'react-router-dom'

import logoUrl from '@/assets/logo.png'
import { useAccessProfile } from '@/features/access/accessContext'
import { useAuth } from '@/features/auth/authContext'
import { accessRoleDisplayLabel } from '@/features/admin/types/accessManagement'

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
  const { user, signOut } = useAuth()
  // Identity display sources the role exclusively from the Access
  // Management profile (`get_my_access_profile` → `normalized.accessRole`),
  // never from `staff_members.primary_role` or any other staff metadata
  // field. The auth `user.email` is used as a fall-back only when the
  // RPC has not returned an `email` of its own yet — which keeps the
  // header populated during the brief access-profile load on first
  // paint instead of flashing an empty slot.
  const { normalized } = useAccessProfile()
  const email = normalized?.email ?? user?.email ?? null
  const roleLabel = normalized?.accessRole
    ? accessRoleDisplayLabel(normalized.accessRole)
    : null

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
        <nav
          className="flex min-w-0 items-center gap-3 text-sm sm:gap-4"
          data-testid="top-nav-user"
        >
          {/*
            Compact identity block. On `sm`+ both lines render: email on
            top, role beneath in smaller muted text. On mobile only the
            role pill is shown — the email is hidden (it's already in
            view on the Access page) so Sign out stays comfortably
            visible alongside the hamburger and logo, and the recent
            Guest Quote mobile tightening is not disturbed.
          */}
          {email || roleLabel ? (
            <div className="flex min-w-0 items-center gap-2">
              {email ? (
                <div className="hidden min-w-0 text-right leading-tight sm:block">
                  <div
                    className="max-w-[16rem] truncate text-xs font-medium text-slate-800 lg:max-w-[22rem]"
                    title={email}
                    data-testid="top-nav-user-email"
                  >
                    {email}
                  </div>
                  {roleLabel ? (
                    <div
                      className="text-[11px] text-slate-500"
                      data-testid="top-nav-user-role-sub"
                    >
                      Role: {roleLabel}
                    </div>
                  ) : null}
                </div>
              ) : null}
              {roleLabel ? (
                <span
                  className="inline-flex items-center rounded-full bg-violet-50 px-2 py-0.5 text-[11px] font-medium text-violet-800 ring-1 ring-inset ring-violet-200 sm:hidden"
                  data-testid="top-nav-user-role-pill"
                >
                  {roleLabel}
                </span>
              ) : null}
            </div>
          ) : null}
          <button
            type="button"
            onClick={() => void onSignOut()}
            className="shrink-0 text-slate-600 hover:text-slate-900"
          >
            Sign out
          </button>
        </nav>
      </div>
    </header>
  )
}
