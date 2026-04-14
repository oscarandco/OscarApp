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

/**
 * Primary source of truth: access_role.
 * Stored roles are `stylist` | `assistant` | `manager` | `admin` (see DB constraint).
 * `stylist` and `assistant` are self-only (own payroll rows); neither is elevated.
 * Legacy `self` (pre-rename) behaves like `stylist` for elevation. `superadmin` maps to admin for elevation.
 * Optional is_admin / is_manager from RPC are applied as extras when present.
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
  const fromRoleManager = role === 'manager'
  // stylist / assistant / legacy self: not elevated from role — payroll-only unless flags apply

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
    accessRole,
    isActive: pickBool(row.is_active, true),
    isAdmin,
    isManager,
    hasElevatedAccess,
  }
}
