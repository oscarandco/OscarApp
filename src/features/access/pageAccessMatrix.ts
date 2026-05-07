/**
 * Static page access matrix (fallback when DB permissions are unavailable).
 * Kept free of React hooks so `accessContext` can merge RPC rows without cycles.
 */

/** App role keys (stored in role_page_permissions + resolved from staff_member_user_access.access_role). */
export type RoleKey =
  | 'assistant'
  | 'stylist'
  | 'reception'
  | 'manager'
  | 'assistant_uat'
  | 'stylist_uat'
  | 'reception_uat'
  | 'manager_uat'
  | 'admin'

/** Canonical column order for Role Permissions UI and Access Management dropdown order within groups. */
export const ROLE_KEYS: RoleKey[] = [
  'assistant',
  'stylist',
  'reception',
  'manager',
  'assistant_uat',
  'stylist_uat',
  'reception_uat',
  'manager_uat',
  'admin',
]

/** Short labels for compact table headers (same order as ROLE_KEYS). */
export const ROLE_DISPLAY_LABELS: Record<RoleKey, string> = {
  assistant: 'Assistant',
  stylist: 'Stylist',
  reception: 'Reception',
  manager: 'Manager',
  assistant_uat: 'Assistant UAT',
  stylist_uat: 'Stylist UAT',
  reception_uat: 'Reception UAT',
  manager_uat: 'Manager UAT',
  admin: 'Admin',
}

/** Subtle vertical divider before Standard→UAT and UAT→Admin column groups. */
export function roleColumnDividerClass(roleKey: RoleKey): string {
  if (roleKey === 'assistant_uat' || roleKey === 'admin') {
    return 'border-l border-slate-200'
  }
  return ''
}

/**
 * One `PageId` per navigable page in the app. The three "Main" pages
 * intentionally use a single id even when the page has detail routes
 * (e.g. `/app/my-sales/:payWeekStart` shares `my_payroll`) because the
 * matrix rule is identical for both.
 */
export type PageId =
  | 'my_payroll'
  | 'guest_quote'
  | 'previous_quotes'
  | 'kpi_dashboard'
  | 'weekly_payroll'
  | 'commission_breakdown'
  | 'imports'
  | 'staff'
  | 'products'
  | 'quotes'
  | 'remuneration'
  | 'access'
  | 'role_permissions'

export type PageAccessLevel = 'none' | 'view' | 'full'

/** Row order for documentation / legacy tooling. */
export const PAGE_MATRIX_ROW_ORDER: PageId[] = [
  'my_payroll',
  'guest_quote',
  'previous_quotes',
  'kpi_dashboard',
  'weekly_payroll',
  'commission_breakdown',
  'imports',
  'staff',
  'products',
  'quotes',
  'remuneration',
  'access',
  'role_permissions',
]

const O = 'none' as const
const V = 'view' as const
const F = 'full' as const

/**
 * Exact access matrix default/fallback. DB `role_page_permissions` is seeded
 * to match; merged rows override at runtime when loaded.
 *
 * Reception defaults (non-UAT): quotes-focused; UAT mirrors base role where noted.
 */
export const PAGE_ACCESS_MATRIX: Record<PageId, Record<RoleKey, PageAccessLevel>> = {
  my_payroll: {
    assistant: F,
    stylist: F,
    reception: O,
    manager: F,
    assistant_uat: F,
    stylist_uat: F,
    reception_uat: O,
    manager_uat: F,
    admin: F,
  },
  guest_quote: {
    assistant: F,
    stylist: F,
    reception: F,
    manager: F,
    assistant_uat: F,
    stylist_uat: F,
    reception_uat: F,
    manager_uat: F,
    admin: F,
  },
  previous_quotes: {
    assistant: F,
    stylist: F,
    reception: F,
    manager: F,
    assistant_uat: F,
    stylist_uat: F,
    reception_uat: F,
    manager_uat: F,
    admin: F,
  },
  kpi_dashboard: {
    assistant: F,
    stylist: F,
    reception: O,
    manager: F,
    assistant_uat: F,
    stylist_uat: F,
    reception_uat: O,
    manager_uat: F,
    admin: F,
  },
  weekly_payroll: {
    assistant: O,
    stylist: O,
    reception: O,
    manager: O,
    assistant_uat: O,
    stylist_uat: O,
    reception_uat: O,
    manager_uat: O,
    admin: F,
  },
  commission_breakdown: {
    assistant: O,
    stylist: O,
    reception: O,
    manager: O,
    assistant_uat: O,
    stylist_uat: O,
    reception_uat: O,
    manager_uat: O,
    admin: F,
  },
  imports: {
    assistant: O,
    stylist: O,
    reception: O,
    manager: F,
    assistant_uat: O,
    stylist_uat: O,
    reception_uat: O,
    manager_uat: F,
    admin: F,
  },
  staff: {
    assistant: O,
    stylist: O,
    reception: O,
    manager: O,
    assistant_uat: O,
    stylist_uat: O,
    reception_uat: O,
    manager_uat: O,
    admin: F,
  },
  products: {
    assistant: O,
    stylist: O,
    reception: O,
    manager: O,
    assistant_uat: O,
    stylist_uat: O,
    reception_uat: O,
    manager_uat: O,
    admin: F,
  },
  quotes: {
    assistant: O,
    stylist: O,
    reception: O,
    manager: O,
    assistant_uat: O,
    stylist_uat: O,
    reception_uat: O,
    manager_uat: O,
    admin: F,
  },
  remuneration: {
    assistant: O,
    stylist: O,
    reception: O,
    manager: O,
    assistant_uat: O,
    stylist_uat: O,
    reception_uat: O,
    manager_uat: O,
    admin: F,
  },
  access: {
    assistant: O,
    stylist: O,
    reception: O,
    manager: V,
    assistant_uat: O,
    stylist_uat: O,
    reception_uat: O,
    manager_uat: V,
    admin: F,
  },
  role_permissions: {
    assistant: O,
    stylist: O,
    reception: O,
    manager: O,
    assistant_uat: O,
    stylist_uat: O,
    reception_uat: O,
    manager_uat: O,
    admin: F,
  },
}

export type EffectivePageMatrix = Record<PageId, Record<RoleKey, PageAccessLevel>>

function isPageAccessLevel(v: string): v is PageAccessLevel {
  return v === 'none' || v === 'view' || v === 'full'
}

function isRoleKey(v: string): v is RoleKey {
  return (ROLE_KEYS as readonly string[]).includes(v)
}

function isPageId(v: string): v is PageId {
  return v in PAGE_ACCESS_MATRIX
}

/** Overlay DB rows onto the static matrix (invalid pairs are ignored). */
export function mergeRolePagePermissionRows(
  rows: Array<{ page_id: string; role_key: string; access_level: string }>,
): EffectivePageMatrix {
  const out = structuredClone(PAGE_ACCESS_MATRIX) as EffectivePageMatrix
  for (const r of rows) {
    const p = r.page_id
    const rk = r.role_key
    const lvl = r.access_level
    if (!isPageId(p) || !isRoleKey(rk) || !isPageAccessLevel(lvl)) continue
    out[p][rk] = lvl
  }
  return out
}
