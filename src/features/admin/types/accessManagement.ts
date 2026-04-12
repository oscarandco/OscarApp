/**
 * Rows from `get_admin_access_mappings()`.
 */
export type AdminAccessMappingRow = {
  mapping_id: string
  user_id: string
  email: string | null
  staff_member_id: string
  staff_display_name: string | null
  staff_full_name: string | null
  access_role: string | null
  is_active: boolean
  created_at: string | null
  updated_at: string | null
}

/** `search_staff_members()` */
export type StaffMemberSearchRow = {
  staff_member_id: string
  display_name: string | null
  full_name: string | null
}

/** `search_auth_users()` */
export type AuthUserSearchRow = {
  user_id: string
  email: string | null
}

/** Stored values for `staff_member_user_access.access_role` (DB check constraint). */
export const ACCESS_ROLE_OPTIONS = [
  { value: 'self', label: 'Stylist' },
  { value: 'manager', label: 'Manager' },
  { value: 'admin', label: 'Admin' },
] as const

const DISPLAY_BY_STORED: Record<string, string> = {
  self: 'Stylist',
  manager: 'Manager',
  admin: 'Admin',
  /** Legacy stored values — label only; new rows use `self` / `manager` / `admin`. */
  stylist: 'Stylist',
  superadmin: 'Admin',
}

/** User-facing label for a stored access_role (table cells, summaries). */
export function accessRoleDisplayLabel(stored: string | null | undefined): string {
  if (stored == null || String(stored).trim() === '') return '—'
  const k = String(stored).trim().toLowerCase()
  return DISPLAY_BY_STORED[k] ?? stored
}

const VALID_FORM_ROLES = new Set(['self', 'manager', 'admin'])

/** Maps DB / legacy values to a form-safe role (only self | manager | admin). */
export function normalizeAccessRoleForForm(
  raw: string | null | undefined,
): 'self' | 'manager' | 'admin' {
  const r = (raw ?? '').trim().toLowerCase()
  if (r === 'stylist') return 'self'
  if (r === 'superadmin') return 'admin'
  if (VALID_FORM_ROLES.has(r)) return r as 'self' | 'manager' | 'admin'
  return 'self'
}
