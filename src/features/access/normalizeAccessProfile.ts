import type { AccessProfile, NormalizedAccess } from '@/features/access/types'

function pickString(v: unknown): string | null {
  if (v == null) return null
  if (typeof v === 'string') return v
  return String(v)
}

function pickBool(v: unknown, fallback = false): boolean {
  if (typeof v === 'boolean') return v
  return fallback
}

function pickNumber(v: unknown): number | null {
  if (v == null) return null
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  if (typeof v === 'string') {
    const n = Number(v)
    return Number.isFinite(n) ? n : null
  }
  return null
}

/**
 * Primary source of truth: access_role.
 * Stored roles match `staff_member_user_access.access_role` (see DB constraint).
 * Elevated = admin/superadmin, manager, manager_uat (imports/admin shell); stylist/assistant/reception UAT variants are not elevated unless flagged.
 * Legacy `self` behaves like stylist. Optional is_admin / is_manager from RPC are applied as extras when present.
 */
export function normalizeAccessProfile(
  row: AccessProfile,
  sessionUserId: string | null,
  sessionEmail: string | null,
): NormalizedAccess {
  const roleRaw = pickString(row.access_role)
  const accessRole = roleRaw ?? null
  const role = accessRole?.trim().toLowerCase() ?? ''

  const fromRoleAdmin = role === 'admin' || role === 'superadmin'
  const fromRoleManager = role === 'manager' || role === 'manager_uat'

  const fromFlagAdmin = pickBool(row.is_admin, false)
  const fromFlagManager = pickBool(row.is_manager, false)

  const isAdmin = fromRoleAdmin || fromFlagAdmin
  const isManager = fromRoleManager || fromFlagManager
  const hasElevatedAccess = isAdmin || isManager

  return {
    userId: pickString(row.user_id) ?? sessionUserId,
    email: pickString(row.email) ?? sessionEmail,
    staffMemberId: pickString(row.staff_member_id),
    staffDisplayName: pickString(row.staff_display_name),
    staffFullName: pickString(row.staff_full_name),
    staffPrimaryRole: pickString(row.staff_primary_role),
    staffFte: pickNumber(row.staff_fte),
    accessRole,
    isActive: pickBool(row.is_active, true),
    isAdmin,
    isManager,
    hasElevatedAccess,
  }
}
