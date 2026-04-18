import type { ReactNode } from 'react'
import { Navigate } from 'react-router-dom'

import { useCanViewPage } from '@/features/access/pageAccess'
import type { PageId } from '@/features/access/pageAccess'

type RequirePageAccessProps = {
  pageId: PageId
  children: ReactNode
}

/**
 * Route-level guard backed by the central `PAGE_ACCESS_MATRIX` in
 * `src/features/access/pageAccess.ts`. Used instead of page-specific
 * access checks so that sidebar visibility and URL guards stay in
 * lockstep with the same matrix.
 *
 * Redirect target mirrors `RequireAdminAccess` — blocked users land on
 * `/app/payroll`, which every authenticated role is allowed to view.
 *
 * This intentionally treats `'view'` and `'full'` the same way:
 * manager "view only" pages (currently just Access) render the page,
 * and the page itself is responsible for hiding/disabling write
 * actions. Page-level branching can use `useIsPageViewOnly(pageId)`.
 *
 * Loading state is handled upstream by `AppBootstrapGate`, which waits
 * for the access profile RPC before mounting any authenticated route,
 * so no loading branch is needed here.
 */
export function RequirePageAccess({ pageId, children }: RequirePageAccessProps) {
  const canView = useCanViewPage(pageId)
  if (!canView) {
    return <Navigate to="/app/payroll" replace />
  }
  return <>{children}</>
}
