import { NavLink } from 'react-router-dom'

import { useHasElevatedAccess } from '@/features/access/accessContext'

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
function NavSectionHeading({ children }: { children: React.ReactNode }) {
  return (
    <p className="px-3 pb-0.5 pt-3 text-[11px] font-semibold uppercase tracking-wide text-slate-400 first:pt-0">
      {children}
    </p>
  )
}

export function SideNav() {
  const elevated = useHasElevatedAccess()

  return (
    <aside className="hidden w-52 shrink-0 overflow-y-auto border-r border-slate-200 bg-white lg:block">
      <nav className="flex flex-col gap-0.5 p-3">
        <NavSectionHeading>Main</NavSectionHeading>
        <NavLink to="/app/payroll" className={linkClass} end>
          My payroll
        </NavLink>
        <NavLink to="/app/quote" className={linkClass}>
          Guest quote
        </NavLink>
        <NavLink to="/app/quotes" className={linkClass}>
          Previous quotes
        </NavLink>

        {elevated ? (
          <>
            <NavSectionHeading>Admin</NavSectionHeading>
            <NavLink to="/app/admin/weekly-commission" className={linkClass}>
              Weekly Payroll
            </NavLink>
            <NavLink to="/app/admin/payroll" className={linkClass}>
              Commission Breakdown
            </NavLink>
            <NavLink to="/app/admin/imports" className={linkClass}>
              Imports
            </NavLink>

            <NavSectionHeading>Configuration</NavSectionHeading>
            <NavLink to="/app/admin/staff" className={linkClass}>
              Staff
            </NavLink>
            <NavLink to="/app/admin/products" className={linkClass}>
              Products
            </NavLink>
            <NavLink to="/app/admin/quotes" className={linkClass}>
              Quotes
            </NavLink>
            <NavLink to="/app/admin/remuneration" className={linkClass}>
              Remuneration
            </NavLink>
            <NavLink to="/app/admin/access" className={linkClass}>
              Access
            </NavLink>
          </>
        ) : null}
      </nav>
    </aside>
  )
}
