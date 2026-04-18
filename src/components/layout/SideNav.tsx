import { useEffect, type ReactNode } from 'react'
import { NavLink } from 'react-router-dom'

import { useCanViewPage } from '@/features/access/pageAccess'

const linkClass = ({ isActive }: { isActive: boolean }) =>
  [
    'block rounded-md px-3 py-1.5 text-sm font-medium',
    isActive
      ? 'bg-violet-50 text-violet-900'
      : 'text-slate-600 hover:bg-slate-100 hover:text-slate-900',
  ].join(' ')

/**
 * Section heading used above each grouped block of nav links. Kept
 * visually quieter than the links themselves (smaller type, muted
 * colour, reduced tracking) so it doesn't compete with the items.
 */
function NavSectionHeading({ children }: { children: ReactNode }) {
  return (
    <p className="px-3 pb-0.5 pt-3 text-[11px] font-semibold uppercase tracking-wide text-slate-400 first:pt-0">
      {children}
    </p>
  )
}

/**
 * Inner render of every nav link, shared between the persistent desktop
 * sidebar and the mobile slide-over drawer. Kept as an inline component
 * so both renderings stay perfectly in sync when new pages are added.
 *
 * `onNavigate` fires after every `NavLink` click. The desktop renderer
 * leaves it undefined (no-op). The mobile drawer passes a callback that
 * closes itself, so tapping a link always dismisses the overlay.
 */
function NavBody({ onNavigate }: { onNavigate?: () => void }) {
  const canMyPayroll = useCanViewPage('my_payroll')
  const canGuestQuote = useCanViewPage('guest_quote')
  const canPreviousQuotes = useCanViewPage('previous_quotes')

  const canWeeklyPayroll = useCanViewPage('weekly_payroll')
  const canCommissionBreakdown = useCanViewPage('commission_breakdown')
  const canImports = useCanViewPage('imports')

  const canStaff = useCanViewPage('staff')
  const canProducts = useCanViewPage('products')
  const canQuotes = useCanViewPage('quotes')
  const canRemuneration = useCanViewPage('remuneration')
  const canAccess = useCanViewPage('access')

  const anyMain = canMyPayroll || canGuestQuote || canPreviousQuotes
  const anyAdmin = canWeeklyPayroll || canCommissionBreakdown || canImports
  const anyConfig =
    canStaff || canProducts || canQuotes || canRemuneration || canAccess

  const handleClick = onNavigate ? () => onNavigate() : undefined

  return (
    <nav className="flex flex-col gap-0.5 p-3">
      {anyMain ? (
        <>
          <NavSectionHeading>Main</NavSectionHeading>
          {canMyPayroll ? (
            <NavLink
              to="/app/my-sales"
              className={linkClass}
              end
              onClick={handleClick}
            >
              My sales
            </NavLink>
          ) : null}
          {canGuestQuote ? (
            <NavLink
              to="/app/guest-quote"
              className={linkClass}
              onClick={handleClick}
            >
              Guest quote
            </NavLink>
          ) : null}
          {canPreviousQuotes ? (
            <NavLink
              to="/app/previous-quotes"
              className={linkClass}
              onClick={handleClick}
            >
              Previous quotes
            </NavLink>
          ) : null}
        </>
      ) : null}

      {anyAdmin ? (
        <>
          <NavSectionHeading>Admin</NavSectionHeading>
          {canWeeklyPayroll ? (
            <NavLink
              to="/app/admin/weekly-payroll"
              className={linkClass}
              onClick={handleClick}
            >
              Weekly payroll
            </NavLink>
          ) : null}
          {canCommissionBreakdown ? (
            <NavLink
              to="/app/admin/sales-summary"
              className={linkClass}
              onClick={handleClick}
            >
              Sales summary
            </NavLink>
          ) : null}
          {canImports ? (
            <NavLink
              to="/app/admin/import-sales-data"
              className={linkClass}
              onClick={handleClick}
            >
              Import sales data
            </NavLink>
          ) : null}
        </>
      ) : null}

      {anyConfig ? (
        <>
          <NavSectionHeading>Configuration</NavSectionHeading>
          {canStaff ? (
            <NavLink
              to="/app/admin/staff"
              className={linkClass}
              onClick={handleClick}
            >
              Staff
            </NavLink>
          ) : null}
          {canProducts ? (
            <NavLink
              to="/app/admin/products"
              className={linkClass}
              onClick={handleClick}
            >
              Products
            </NavLink>
          ) : null}
          {canQuotes ? (
            <NavLink
              to="/app/admin/quotes"
              className={linkClass}
              onClick={handleClick}
            >
              Quotes
            </NavLink>
          ) : null}
          {canRemuneration ? (
            <NavLink
              to="/app/admin/remuneration"
              className={linkClass}
              onClick={handleClick}
            >
              Remuneration
            </NavLink>
          ) : null}
          {canAccess ? (
            <NavLink
              to="/app/admin/access"
              className={linkClass}
              onClick={handleClick}
            >
              Access
            </NavLink>
          ) : null}
        </>
      ) : null}
    </nav>
  )
}

/**
 * Sidebar navigation.
 *
 * Desktop (≥ lg): persistent left rail (`hidden w-52 ... lg:block`).
 *
 * Mobile (< lg): closed by default. When `mobileOpen` is true, renders
 * a slide-over drawer with a dimmed backdrop. Tapping a link or the
 * backdrop dismisses it via `onMobileClose`.
 *
 * Visibility of individual links is driven by `useCanViewPage(pageId)`,
 * which reads the centralised `PAGE_ACCESS_MATRIX`. The same matrix
 * also backs `RequirePageAccess` on every admin/config route, so a
 * hidden sidebar item can never be reached by URL either.
 */
export function SideNav({
  mobileOpen = false,
  onMobileClose,
}: {
  mobileOpen?: boolean
  onMobileClose?: () => void
} = {}) {
  // Lock body scroll while the mobile drawer is open so the background
  // doesn't drift under the user's finger.
  useEffect(() => {
    if (!mobileOpen) return
    const prev = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.body.style.overflow = prev
    }
  }, [mobileOpen])

  // Dismiss on Escape so keyboard users can close the drawer without a
  // pointer interaction.
  useEffect(() => {
    if (!mobileOpen || !onMobileClose) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onMobileClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [mobileOpen, onMobileClose])

  return (
    <>
      <aside
        className="hidden w-52 shrink-0 overflow-y-auto border-r border-slate-200 bg-white lg:block"
        data-testid="side-nav-desktop"
      >
        <NavBody />
      </aside>
      {mobileOpen ? (
        <div
          className="fixed inset-0 z-40 lg:hidden"
          role="dialog"
          aria-modal="true"
          aria-label="Main navigation"
          data-testid="side-nav-mobile"
        >
          <button
            type="button"
            aria-label="Close menu"
            onClick={onMobileClose}
            className="absolute inset-0 bg-slate-900/40"
            data-testid="side-nav-mobile-overlay"
          />
          <aside className="absolute left-0 top-0 h-full w-64 max-w-[80%] overflow-y-auto border-r border-slate-200 bg-white shadow-xl">
            <NavBody onNavigate={onMobileClose} />
          </aside>
        </div>
      ) : null}
    </>
  )
}
