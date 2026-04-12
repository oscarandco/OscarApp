import { Navigate, Outlet } from 'react-router-dom'

import { useHasElevatedAccess } from '@/features/access/accessContext'

/** Uses normalized access from bootstrap; only elevated roles reach admin routes. */
export function RequireAdminAccess() {
  const elevated = useHasElevatedAccess()

  if (!elevated) {
    return <Navigate to="/app/payroll" replace />
  }

  return <Outlet />
}
