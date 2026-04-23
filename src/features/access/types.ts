/**
 * Row returned by get_my_access_profile().
 * Backend may add columns; extra keys are allowed.
 */
export type AccessProfile = {
  user_id?: string | null
  email?: string | null
  staff_member_id?: string | null
  staff_display_name?: string | null
  staff_full_name?: string | null
  /**
   * `staff_members.primary_role` for the mapped staff member. Added
   * so the desktop header can show the Kitomba-side job title
   * (e.g. "Senior Stylist") alongside the access_role pill.
   */
  staff_primary_role?: string | null
  /**
   * `staff_members.fte` for the mapped staff member. Supabase-js
   * serialises `numeric` as string, so normalization coerces to
   * `number` and falls back to `null` for non-finite values.
   */
  staff_fte?: number | string | null
  access_role?: string | null
  is_active?: boolean | null
  /** Optional extras if the RPC exposes them — normalization prefers access_role. */
  is_admin?: boolean | null
  is_manager?: boolean | null
  [key: string]: unknown
}

/** App-ready access state derived from AccessProfile + session. */
export type NormalizedAccess = {
  userId: string | null
  email: string | null
  staffMemberId: string | null
  staffDisplayName: string | null
  staffFullName: string | null
  /** `staff_members.primary_role`; null when missing / no mapping. */
  staffPrimaryRole: string | null
  /** `staff_members.fte` coerced to `number`; null when missing / no mapping. */
  staffFte: number | null
  accessRole: string | null
  isActive: boolean
  /** True when access_role is admin or legacy superadmin (or optional is_admin flag). */
  isAdmin: boolean
  /** True when access_role is manager (or optional is_manager flag). */
  isManager: boolean
  /** True for admin, legacy superadmin, or manager (elevated app areas); stylist/assistant are not elevated. */
  hasElevatedAccess: boolean
}
