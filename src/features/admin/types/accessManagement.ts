/**
 * Rows from `get_admin_access_mappings()`.
 */
export type AdminAccessMappingRow = {
  mapping_id: string
  user_id: string
  email: string | null
  staff_member_id: string | null
  staff_display_name: string | null
  staff_full_name: string | null
  /** display_name if set, else full_name (from get_admin_access_mappings). */
  staff_name: string | null
  access_role: string | null
  is_active: boolean
  created_at: string | null
  updated_at: string | null
  /** Most recent auth.users.last_sign_in_at for this mapping's user. */
  last_sign_in_at: string | null
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
  /** auth.users.created_at — only populated by `search_auth_users`. */
  created_at?: string | null
  /** auth.users.last_sign_in_at — only populated by `search_auth_users`. */
  last_sign_in_at?: string | null
}

/** Stored values for `staff_member_user_access.access_role` (DB check constraint). */
export const ACCESS_ROLE_OPTIONS = [
  { value: 'stylist', label: 'Stylist' },
  { value: 'assistant', label: 'Assistant' },
  { value: 'manager', label: 'Manager' },
  { value: 'admin', label: 'Admin' },
] as const

export type StoredAccessRole = (typeof ACCESS_ROLE_OPTIONS)[number]['value']

/** Stylist and Assistant must have a linked staff member before save. */
export function staffMemberRequiredForRole(role: string | null | undefined): boolean {
  const r = (role ?? '').trim().toLowerCase()
  return r === 'stylist' || r === 'assistant'
}

/** Show staff picker for all roles; Stylist/Assistant require a selection before save. */
export function roleShowsStaffMemberField(role: string | null | undefined): boolean {
  const r = (role ?? '').trim().toLowerCase()
  return (
    r === 'stylist' || r === 'assistant' || r === 'manager' || r === 'admin'
  )
}

const DISPLAY_BY_STORED: Record<string, string> = {
  stylist: 'Stylist',
  assistant: 'Assistant',
  manager: 'Manager',
  admin: 'Admin',
  /** Legacy before `stylist` rename */
  self: 'Stylist',
  superadmin: 'Admin',
}

/** User-facing label for a stored access_role (table cells, summaries). */
export function accessRoleDisplayLabel(stored: string | null | undefined): string {
  if (stored == null || String(stored).trim() === '') return '—'
  const k = String(stored).trim().toLowerCase()
  return DISPLAY_BY_STORED[k] ?? stored
}

const VALID_FORM_ROLES = new Set<string>([
  'stylist',
  'assistant',
  'manager',
  'admin',
])

/** Maps DB / legacy values to a form-safe role (stylist | assistant | manager | admin). */
export function normalizeAccessRoleForForm(
  raw: string | null | undefined,
): StoredAccessRole {
  const r = (raw ?? '').trim().toLowerCase()
  if (r === 'self') return 'stylist'
  if (r === 'superadmin') return 'admin'
  if (VALID_FORM_ROLES.has(r)) return r as StoredAccessRole
  return 'stylist'
}
