import type { AdminPayrollSummaryRow } from '@/features/admin/types'
import { tableColumnTitle } from '@/lib/formatters'

export const ADMIN_PAYROLL_SUMMARY_COLUMNS_STORAGE_KEY =
  'admin-payroll-summary-columns'

/** Admin middle columns (between Week / Pay week start and Detail). Includes staff_full_name. */
export type AdminMiddleColumnId =
  | 'pay_week_end'
  | 'pay_date'
  | 'location'
  | 'derived_staff_paid_id'
  | 'derived_staff_paid_display_name'
  | 'derived_staff_paid_full_name'
  | 'staff_full_name'
  | 'derived_staff_paid_remuneration_plan'
  | 'total_sales_ex_gst'
  | 'row_count'
  | 'payable_line_count'
  | 'expected_no_commission_line_count'
  | 'zero_value_line_count'
  | 'review_line_count'
  | 'total_actual_commission_ex_gst'
  | 'total_theoretical_commission_ex_gst'
  | 'total_assistant_commission_ex_gst'
  | 'unconfigured_paid_staff_line_count'
  | 'has_unconfigured_paid_staff_rows'
  | 'user_id'
  | 'access_role'

const ALL_ADMIN_MIDDLE_IDS: readonly AdminMiddleColumnId[] = [
  'pay_week_end',
  'pay_date',
  'location',
  'derived_staff_paid_id',
  'derived_staff_paid_display_name',
  'derived_staff_paid_full_name',
  'staff_full_name',
  'derived_staff_paid_remuneration_plan',
  'total_sales_ex_gst',
  'row_count',
  'payable_line_count',
  'expected_no_commission_line_count',
  'zero_value_line_count',
  'review_line_count',
  'total_actual_commission_ex_gst',
  'total_theoretical_commission_ex_gst',
  'total_assistant_commission_ex_gst',
  'unconfigured_paid_staff_line_count',
  'has_unconfigured_paid_staff_rows',
  'user_id',
  'access_role',
]

/** Same lock as weekly payroll: Pay Date stays visible. */
export const ADMIN_MIDDLE_LOCKED_VISIBLE: ReadonlySet<AdminMiddleColumnId> =
  new Set(['pay_date'])

/** Labels match `tableColumnTitle` for the resolved row key (admin headers unchanged). */
export function adminMiddleColumnLabel(id: AdminMiddleColumnId): string {
  if (id === 'location') return tableColumnTitle('location_name')
  return tableColumnTitle(id)
}

/** Default visible middle columns (aligned with weekly payroll pattern; admin adds display + staff full name). */
const DEFAULT_VISIBLE_ADMIN_MIDDLE: readonly AdminMiddleColumnId[] = [
  'pay_date',
  'pay_week_end',
  'location',
  'derived_staff_paid_display_name',
  'staff_full_name',
  'total_sales_ex_gst',
  'total_theoretical_commission_ex_gst',
  'total_actual_commission_ex_gst',
]

const DEFAULT_HIDDEN_ADMIN: AdminMiddleColumnId[] =
  ALL_ADMIN_MIDDLE_IDS.filter(
    (id) => !(DEFAULT_VISIBLE_ADMIN_MIDDLE as readonly string[]).includes(id),
  )

export const DEFAULT_ADMIN_MIDDLE_ORDER: AdminMiddleColumnId[] = [
  ...DEFAULT_VISIBLE_ADMIN_MIDDLE,
  ...ALL_ADMIN_MIDDLE_IDS.filter((id) => !DEFAULT_VISIBLE_ADMIN_MIDDLE.includes(id)),
]

export type AdminColumnPreferences = {
  order: AdminMiddleColumnId[]
  hidden: AdminMiddleColumnId[]
}

export function defaultAdminColumnPreferences(): AdminColumnPreferences {
  return {
    order: [...DEFAULT_ADMIN_MIDDLE_ORDER],
    hidden: [...DEFAULT_HIDDEN_ADMIN],
  }
}

export function isAdminMiddleColumnId(s: string): s is AdminMiddleColumnId {
  return (ALL_ADMIN_MIDDLE_IDS as readonly string[]).includes(s)
}

export function parseStoredAdminPreferences(
  raw: string | null,
): AdminColumnPreferences | null {
  if (raw == null || raw.trim() === '') return null
  try {
    const v = JSON.parse(raw) as unknown
    if (v == null || typeof v !== 'object') return null
    const orderRaw = (v as { order?: unknown }).order
    const hiddenRaw = (v as { hidden?: unknown }).hidden
    if (!Array.isArray(orderRaw)) return null
    const order = orderRaw.filter((x): x is AdminMiddleColumnId =>
      typeof x === 'string' && isAdminMiddleColumnId(x),
    )
    const hidden = Array.isArray(hiddenRaw)
      ? hiddenRaw.filter((x): x is AdminMiddleColumnId =>
          typeof x === 'string' && isAdminMiddleColumnId(x),
        )
      : []
    if (order.length === 0) return null
    const seen = new Set(order)
    for (const id of ALL_ADMIN_MIDDLE_IDS) {
      if (!seen.has(id)) order.push(id)
    }
    const deduped: AdminMiddleColumnId[] = []
    seen.clear()
    for (const id of order) {
      if (!seen.has(id)) {
        seen.add(id)
        deduped.push(id)
      }
    }
    const hiddenSet = new Set(
      hidden.filter((id) => !ADMIN_MIDDLE_LOCKED_VISIBLE.has(id)),
    )
    return { order: deduped, hidden: [...hiddenSet] }
  } catch {
    return null
  }
}

export function loadAdminColumnPreferences(): AdminColumnPreferences {
  if (typeof window === 'undefined') return defaultAdminColumnPreferences()
  try {
    const parsed = parseStoredAdminPreferences(
      window.localStorage.getItem(ADMIN_PAYROLL_SUMMARY_COLUMNS_STORAGE_KEY),
    )
    return parsed ?? defaultAdminColumnPreferences()
  } catch {
    return defaultAdminColumnPreferences()
  }
}

export function saveAdminColumnPreferences(prefs: AdminColumnPreferences): void {
  if (typeof window === 'undefined') return
  const hidden = prefs.hidden.filter((id) => !ADMIN_MIDDLE_LOCKED_VISIBLE.has(id))
  try {
    window.localStorage.setItem(
      ADMIN_PAYROLL_SUMMARY_COLUMNS_STORAGE_KEY,
      JSON.stringify({ order: prefs.order, hidden }),
    )
  } catch {
    /* quota / private mode */
  }
}

export function resolveRowKeyForAdminMiddleColumn(
  id: AdminMiddleColumnId,
  row: AdminPayrollSummaryRow,
): string | null {
  if (id === 'location') {
    if (row.location_name != null && String(row.location_name).trim() !== '') {
      return 'location_name'
    }
    if (row.location_id != null && String(row.location_id).trim() !== '') {
      return 'location_id'
    }
    return null
  }
  if (id === 'row_count') {
    if (Object.prototype.hasOwnProperty.call(row, 'line_count')) return 'line_count'
    if (Object.prototype.hasOwnProperty.call(row, 'row_count')) return 'row_count'
    return null
  }
  if (id === 'total_actual_commission_ex_gst') {
    if (Object.prototype.hasOwnProperty.call(row, 'total_actual_commission_ex_gst')) {
      return 'total_actual_commission_ex_gst'
    }
    if (Object.prototype.hasOwnProperty.call(row, 'total_actual_commission')) {
      return 'total_actual_commission'
    }
    return null
  }
  if (id === 'total_assistant_commission_ex_gst') {
    if (Object.prototype.hasOwnProperty.call(row, 'total_assistant_commission_ex_gst')) {
      return 'total_assistant_commission_ex_gst'
    }
    if (Object.prototype.hasOwnProperty.call(row, 'total_assistant_commission')) {
      return 'total_assistant_commission'
    }
    return null
  }
  if (Object.prototype.hasOwnProperty.call(row, id)) return id
  return null
}

export type VisibleAdminMiddleColumn = {
  id: AdminMiddleColumnId
  rowKey: string
}

export function visibleAdminMiddleColumns(
  sample: AdminPayrollSummaryRow,
  prefs: AdminColumnPreferences,
): VisibleAdminMiddleColumn[] {
  const hidden = new Set(
    prefs.hidden.filter((id) => !ADMIN_MIDDLE_LOCKED_VISIBLE.has(id)),
  )
  const out: VisibleAdminMiddleColumn[] = []
  for (const id of prefs.order) {
    if (hidden.has(id)) continue
    const rk = resolveRowKeyForAdminMiddleColumn(id, sample)
    if (rk != null) out.push({ id, rowKey: rk })
  }
  return out
}

export function adminMiddleRowKeysForPreferences(
  sample: AdminPayrollSummaryRow,
  prefs: AdminColumnPreferences,
): string[] {
  return visibleAdminMiddleColumns(sample, prefs).map((c) => c.rowKey)
}

export function reorderAdminMiddleColumnOrder(
  order: AdminMiddleColumnId[],
  fromId: AdminMiddleColumnId,
  toId: AdminMiddleColumnId,
): AdminMiddleColumnId[] {
  if (fromId === toId) return [...order]
  if (!order.includes(fromId) || !order.includes(toId)) return [...order]
  const without = order.filter((id) => id !== fromId)
  const insertAt = without.indexOf(toId)
  if (insertAt < 0) return [...order]
  const next = [...without]
  next.splice(insertAt, 0, fromId)
  return next
}
