import { NavLink } from 'react-router-dom'

import { useHasElevatedAccess } from '@/features/access/accessContext'

const linkClass = ({ isActive }: { isActive: boolean }) =>
  [
    'block rounded-md px-3 py-2 text-sm font-medium',
    isActive
      ? 'bg-violet-50 text-violet-900'
      : 'text-slate-600 hover:bg-slate-100 hover:text-slate-900',
  ].join(' ')

export function SideNav() {
  const elevated = useHasElevatedAccess()

  return (
    <aside className="hidden w-52 shrink-0 border-r border-slate-200 bg-white lg:block">
      <nav className="flex flex-col gap-1 p-3">
        <NavLink to="/app/payroll" className={linkClass} end>
          Weekly summary
        </NavLink>
        {elevated ? (
          <>
            <div className="my-2 border-t border-slate-100" />
            <p className="px-3 text-xs font-semibold uppercase tracking-wide text-slate-500">
              Admin
            </p>
            <NavLink to="/app/admin" className={linkClass} end>
              Admin home
            </NavLink>
            <NavLink to="/app/admin/payroll" className={linkClass}>
              Admin weekly payroll
            </NavLink>
            <NavLink to="/app/admin/weekly-commission" className={linkClass}>
              Weekly commission dashboard
            </NavLink>
            <NavLink to="/app/admin/remuneration" className={linkClass}>
              Remuneration configuration
            </NavLink>
            <NavLink to="/app/admin/staff" className={linkClass}>
              Staff configuration
            </NavLink>
            <NavLink to="/app/admin/products" className={linkClass}>
              Product configuration
            </NavLink>
            <NavLink to="/app/admin/access" className={linkClass}>
              Access management
            </NavLink>
            <NavLink to="/app/admin/imports" className={linkClass}>
              Imports
            </NavLink>
          </>
        ) : null}
      </nav>
    </aside>
  )
}
