import type { NormalizedAccess } from '@/features/access/types'

/**
 * Matches `private.user_can_manage_access_mappings()` in the database: only
 * **admin** (and legacy **superadmin** if still allowed by RPC) may create/update mappings — not stylist, assistant, or manager.
 * Ignores optional `is_admin` RPC flags so the UI stays aligned with role-based checks.
 */
export function canManageStaffAccessMappings(
  normalized: NormalizedAccess | null,
): boolean {
  if (!normalized?.isActive) return false
  const r = normalized.accessRole?.trim().toLowerCase() ?? ''
  return r === 'admin' || r === 'superadmin'
}
