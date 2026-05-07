import { useAccessProfile } from '@/features/access/accessContext'
import type { NormalizedAccess } from '@/features/access/types'
import {
  PAGE_ACCESS_MATRIX,
  type EffectivePageMatrix,
  type PageAccessLevel,
  type PageId,
  type RoleKey,
} from '@/features/access/pageAccessMatrix'

export type { EffectivePageMatrix, PageAccessLevel, PageId, RoleKey }
export { PAGE_ACCESS_MATRIX } from '@/features/access/pageAccessMatrix'

/**
 * Semantics of an access level:
 *   • `'full'` — user can view the page AND perform mutations on it.
 *   • `'view'` — user can view the page, but write actions must be
 *                hidden/disabled by the page itself.
 *   • `'none'` — page is hidden from the sidebar AND the route guard
 *                redirects away on direct URL access.
 */

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
  matrix: EffectivePageMatrix = PAGE_ACCESS_MATRIX,
): PageAccessLevel {
  const role = resolveRole(normalized)
  if (role == null) return 'none'
  return matrix[pageId][role]
}

/**
 * Hook variant: returns the access level for the current user on the
 * given page. Returns `'none'` while the access profile is still
 * loading, so callers do not flash allowed UI before we know the
 * user's role.
 *
 * Uses `effectivePageMatrix` from context (DB-backed when available,
 * otherwise the static `PAGE_ACCESS_MATRIX`).
 */
export function usePageAccess(pageId: PageId): PageAccessLevel {
  const { accessState, normalized, effectivePageMatrix } = useAccessProfile()
  if (accessState !== 'ready') return 'none'
  return getPageAccess(pageId, normalized, effectivePageMatrix)
}

/** True when the user can at least view the page (view-only OR full). */
export function useCanViewPage(pageId: PageId): boolean {
  return usePageAccess(pageId) !== 'none'
}

/** True only when the user has view access but is NOT allowed to mutate. */
export function useIsPageViewOnly(pageId: PageId): boolean {
  return usePageAccess(pageId) === 'view'
}
