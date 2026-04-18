import type { ReactNode } from 'react'
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
 * Sidebar navigation.
 *
 * Visibility is driven by `useCanViewPage(pageId)`, which reads the
 * centralised `PAGE_ACCESS_MATRIX` in `src/features/access/pageAccess.ts`.
 * The same matrix also backs `RequirePageAccess` on every admin/config
 * route, so a hidden sidebar item can never be reached by URL either.
 *
 * Hooks are called at the top level (one per `PageId`) so the hook
 * order is stable and obvious — no loops over dynamic arrays.
 */
export function SideNav() {
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

  return (
    <aside className="hidden w-52 shrink-0 overflow-y-auto border-r border-slate-200 bg-white lg:block">
      <nav className="flex flex-col gap-0.5 p-3">
        {anyMain ? (
          <>
            <NavSectionHeading>Main</NavSectionHeading>
            {canMyPayroll ? (
              <NavLink to="/app/my-sales" className={linkClass} end>
                My sales
              </NavLink>
            ) : null}
            {canGuestQuote ? (
              <NavLink to="/app/guest-quote" className={linkClass}>
                Guest quote
              </NavLink>
            ) : null}
            {canPreviousQuotes ? (
              <NavLink to="/app/previous-quotes" className={linkClass}>
                Previous quotes
              </NavLink>
            ) : null}
          </>
        ) : null}

        {anyAdmin ? (
          <>
            <NavSectionHeading>Admin</NavSectionHeading>
            {canWeeklyPayroll ? (
              <NavLink to="/app/admin/weekly-payroll" className={linkClass}>
                Weekly payroll
              </NavLink>
            ) : null}
            {canCommissionBreakdown ? (
              <NavLink to="/app/admin/sales-summary" className={linkClass}>
                Sales summary
              </NavLink>
            ) : null}
            {canImports ? (
              <NavLink
                to="/app/admin/import-sales-data"
                className={linkClass}
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
              <NavLink to="/app/admin/staff" className={linkClass}>
                Staff
              </NavLink>
            ) : null}
            {canProducts ? (
              <NavLink to="/app/admin/products" className={linkClass}>
                Products
              </NavLink>
            ) : null}
            {canQuotes ? (
              <NavLink to="/app/admin/quotes" className={linkClass}>
                Quotes
              </NavLink>
            ) : null}
            {canRemuneration ? (
              <NavLink to="/app/admin/remuneration" className={linkClass}>
                Remuneration
              </NavLink>
            ) : null}
            {canAccess ? (
              <NavLink to="/app/admin/access" className={linkClass}>
                Access
              </NavLink>
            ) : null}
          </>
        ) : null}
      </nav>
    </aside>
  )
}
