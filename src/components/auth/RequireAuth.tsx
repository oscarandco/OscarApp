import { Navigate, Outlet, useLocation } from 'react-router-dom'

import { LoadingState } from '@/components/feedback/LoadingState'
import { useSession } from '@/features/auth/authContext'

export function RequireAuth() {
  const location = useLocation()
  const { user, loading } = useSession()

  if (loading) {
    return <LoadingState fullPage message="Checking session…" />
  }

  if (!user) {
    return <Navigate to="/login" replace state={{ from: location }} />
  }

  return <Outlet />
}
