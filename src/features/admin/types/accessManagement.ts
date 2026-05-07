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

/** Grouped options for Access Management role &lt;select&gt; (optgroup order). */
export const ACCESS_ROLE_OPTGROUPS = [
  {
    label: 'Standard access',
    options: [
      { value: 'assistant', label: 'Assistant' },
      { value: 'stylist', label: 'Stylist' },
      { value: 'reception', label: 'Reception' },
      { value: 'manager', label: 'Manager' },
    ],
  },
  {
    label: 'User Acceptance Testing',
    options: [
      { value: 'assistant_uat', label: 'Assistant UAT' },
      { value: 'stylist_uat', label: 'Stylist UAT' },
      { value: 'reception_uat', label: 'Reception UAT' },
      { value: 'manager_uat', label: 'Manager UAT' },
    ],
  },
  {
    label: 'Admin',
    options: [{ value: 'admin', label: 'Admin' }],
  },
] as const

/** Flat list in canonical order (for legacy callers / validation). */
export const ACCESS_ROLE_OPTIONS = ACCESS_ROLE_OPTGROUPS.flatMap((g) => [...g.options])

export type StoredAccessRole = (typeof ACCESS_ROLE_OPTIONS)[number]['value']

/** Stylist / Assistant (+ UAT) must have a linked staff member before save. */
export function staffMemberRequiredForRole(role: string | null | undefined): boolean {
  const r = (role ?? '').trim().toLowerCase()
  return (
    r === 'stylist' ||
    r === 'assistant' ||
    r === 'stylist_uat' ||
    r === 'assistant_uat'
  )
}

/** Show staff picker for these roles (required or optional per strictStaff). */
export function roleShowsStaffMemberField(role: string | null | undefined): boolean {
  const r = (role ?? '').trim().toLowerCase()
  return (
    r === 'stylist' ||
    r === 'assistant' ||
    r === 'stylist_uat' ||
    r === 'assistant_uat' ||
    r === 'reception' ||
    r === 'reception_uat' ||
    r === 'manager' ||
    r === 'manager_uat' ||
    r === 'admin'
  )
}

const DISPLAY_BY_STORED: Record<string, string> = {
  assistant: 'Assistant',
  stylist: 'Stylist',
  reception: 'Reception',
  manager: 'Manager',
  assistant_uat: 'Assistant UAT',
  stylist_uat: 'Stylist UAT',
  reception_uat: 'Reception UAT',
  manager_uat: 'Manager UAT',
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

const VALID_FORM_ROLES = new Set<string>(
  ACCESS_ROLE_OPTIONS.map((o) => o.value),
)

/** Maps DB / legacy values to a form-safe stored role key. */
export function normalizeAccessRoleForForm(
  raw: string | null | undefined,
): StoredAccessRole {
  const r = (raw ?? '').trim().toLowerCase()
  if (r === 'self') return 'stylist'
  if (r === 'superadmin') return 'admin'
  if (VALID_FORM_ROLES.has(r)) return r as StoredAccessRole
  return 'stylist'
}
