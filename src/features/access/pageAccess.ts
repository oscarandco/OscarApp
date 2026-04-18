import { useAccessProfile } from '@/features/access/accessContext'
import type { NormalizedAccess } from '@/features/access/types'

/**
 * Centralised page access matrix.
 *
 * Goal: every page-visibility and route-guard decision in the app reads
 * from one place. This keeps sidebar hiding and URL guards in lockstep
 * and leaves room to add per-page rules for Assistant / Stylist later
 * without reworking the nav or router.
 *
 * Semantics of an access level:
 *   • `'full'` — user can view the page AND perform mutations on it.
 *   • `'view'` — user can view the page, but write actions must be
 *                hidden/disabled by the page itself.
 *   • `'none'` — page is hidden from the sidebar AND the route guard
 *                redirects away on direct URL access.
 */

/** App-ready role keys. Legacy/DB values are folded into these four. */
export type RoleKey = 'assistant' | 'stylist' | 'manager' | 'admin'

/**
 * One `PageId` per navigable page in the app. The three "Main" pages
 * intentionally use a single id even when the page has detail routes
 * (e.g. `/app/payroll/:payWeekStart` shares `my_payroll`) because the
 * matrix rule is identical for both.
 */
export type PageId =
  | 'my_payroll'
  | 'guest_quote'
  | 'previous_quotes'
  | 'weekly_payroll'
  | 'commission_breakdown'
  | 'imports'
  | 'staff'
  | 'products'
  | 'quotes'
  | 'remuneration'
  | 'access'

export type PageAccessLevel = 'none' | 'view' | 'full'

/**
 * Exact access matrix from the spec. Keep this as the single source of
 * truth — `SideNav` reads it via `useCanViewPage`, `RequirePageAccess`
 * reads it via `getPageAccess`, and pages that need to branch on
 * view-only mode can call `usePageAccess(pageId)`.
 */
export const PAGE_ACCESS_MATRIX: Record<
  PageId,
  Record<RoleKey, PageAccessLevel>
> = {
  my_payroll: {
    assistant: 'full',
    stylist: 'full',
    manager: 'full',
    admin: 'full',
  },
  guest_quote: {
    assistant: 'full',
    stylist: 'full',
    manager: 'full',
    admin: 'full',
  },
  previous_quotes: {
    assistant: 'full',
    stylist: 'full',
    manager: 'full',
    admin: 'full',
  },
  weekly_payroll: {
    assistant: 'none',
    stylist: 'none',
    manager: 'none',
    admin: 'full',
  },
  commission_breakdown: {
    assistant: 'none',
    stylist: 'none',
    manager: 'none',
    admin: 'full',
  },
  imports: {
    assistant: 'none',
    stylist: 'none',
    manager: 'full',
    admin: 'full',
  },
  staff: {
    assistant: 'none',
    stylist: 'none',
    manager: 'none',
    admin: 'full',
  },
  products: {
    assistant: 'none',
    stylist: 'none',
    manager: 'none',
    admin: 'full',
  },
  quotes: {
    assistant: 'none',
    stylist: 'none',
    manager: 'none',
    admin: 'full',
  },
  remuneration: {
    assistant: 'none',
    stylist: 'none',
    manager: 'none',
    admin: 'full',
  },
  access: {
    assistant: 'none',
    stylist: 'none',
    manager: 'view',
    admin: 'full',
  },
}

/**
 * Collapses any stored access_role (including legacy values like
 * `'self'` / `'superadmin'`) into one of the four `RoleKey` buckets
 * the matrix uses. Inactive profiles and unrecognised roles resolve to
 * `null`, which the matrix treats as "no access to anything".
 */
export function resolveRole(
  normalized: NormalizedAccess | null,
): RoleKey | null {
  if (!normalized?.isActive) return null
  const r = (normalized.accessRole ?? '').trim().toLowerCase()
  if (r === 'admin' || r === 'superadmin') return 'admin'
  if (r === 'manager') return 'manager'
  if (r === 'stylist' || r === 'self') return 'stylist'
  if (r === 'assistant') return 'assistant'
  return null
}

/** Plain (non-hook) lookup. Useful inside route guards and tests. */
export function getPageAccess(
  pageId: PageId,
  normalized: NormalizedAccess | null,
): PageAccessLevel {
  const role = resolveRole(normalized)
  if (role == null) return 'none'
  return PAGE_ACCESS_MATRIX[pageId][role]
}

/**
 * Hook variant: returns the access level for the current user on the
 * given page. Returns `'none'` while the access profile is still
 * loading, so callers do not flash allowed UI before we know the
 * user's role.
 */
export function usePageAccess(pageId: PageId): PageAccessLevel {
  const { accessState, normalized } = useAccessProfile()
  if (accessState !== 'ready') return 'none'
  return getPageAccess(pageId, normalized)
}

/** True when the user can at least view the page (view-only OR full). */
export function useCanViewPage(pageId: PageId): boolean {
  return usePageAccess(pageId) !== 'none'
}

/** True only when the user has view access but is NOT allowed to mutate. */
export function useIsPageViewOnly(pageId: PageId): boolean {
  return usePageAccess(pageId) === 'view'
}
