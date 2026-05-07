/**
 * Static page access matrix (fallback when DB permissions are unavailable).
 * Kept free of React hooks so `accessContext` can merge RPC rows without cycles.
 */

/** App-ready role keys. Legacy/DB values are folded into these four. */
export type RoleKey = 'assistant' | 'stylist' | 'manager' | 'admin'

export const ROLE_KEYS: RoleKey[] = ['assistant', 'stylist', 'manager', 'admin']

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

/** Row order for the Role permissions admin matrix UI. */
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

/**
 * Exact access matrix default/fallback. DB `role_page_permissions` is seeded
 * to match; merged rows override at runtime when loaded.
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
  kpi_dashboard: {
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
  role_permissions: {
    assistant: 'none',
    stylist: 'none',
    manager: 'none',
    admin: 'full',
  },
}

export type EffectivePageMatrix = Record<
  PageId,
  Record<RoleKey, PageAccessLevel>
>

function isPageAccessLevel(v: string): v is PageAccessLevel {
  return v === 'none' || v === 'view' || v === 'full'
}

function isRoleKey(v: string): v is RoleKey {
  return v === 'assistant' || v === 'stylist' || v === 'manager' || v === 'admin'
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
