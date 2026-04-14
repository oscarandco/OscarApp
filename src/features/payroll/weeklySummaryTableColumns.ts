import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'

export const PAYROLL_SUMMARY_COLUMNS_STORAGE_KEY = 'payroll-summary-columns'

/** Middle data columns (between Week / Pay week start and Detail). */
export type MiddleColumnId =
  | 'pay_week_end'
  | 'pay_date'
  | 'location'
  | 'derived_staff_paid_id'
  | 'derived_staff_paid_display_name'
  | 'derived_staff_paid_full_name'
  | 'derived_staff_paid_remuneration_plan'
  | 'total_sales_ex_gst'
  /** Maps to API `line_count` (see resolveRowKeyForMiddleColumn). */
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

const ALL_MIDDLE_IDS: readonly MiddleColumnId[] = [
  'pay_week_end',
  'pay_date',
  'location',
  'derived_staff_paid_id',
  'derived_staff_paid_display_name',
  'derived_staff_paid_full_name',
  'derived_staff_paid_remuneration_plan',
  'row_count',
  'payable_line_count',
  'expected_no_commission_line_count',
  'zero_value_line_count',
  'review_line_count',
  'total_sales_ex_gst',
  'total_actual_commission_ex_gst',
  'total_theoretical_commission_ex_gst',
  'total_assistant_commission_ex_gst',
  'unconfigured_paid_staff_line_count',
  'has_unconfigured_paid_staff_rows',
  'user_id',
  'access_role',
]

/** Ids that cannot be hidden (still participate in ordering). */
export const MIDDLE_LOCKED_VISIBLE: ReadonlySet<MiddleColumnId> = new Set([
  'pay_date',
])

export const COLUMN_LABEL: Record<MiddleColumnId, string> = {
  pay_week_end: 'End',
  pay_date: 'Pay Date',
  location: 'Location',
  derived_staff_paid_id: 'Derived staff paid ID',
  derived_staff_paid_display_name: 'Derived staff paid display name',
  derived_staff_paid_full_name: 'Staff Paid',
  derived_staff_paid_remuneration_plan: 'Rem Plan',
  total_sales_ex_gst: 'Total Sales (ex GST)',
  row_count: 'Line count',
  payable_line_count: 'Payable line count',
  expected_no_commission_line_count: 'Expected no commission line count',
  zero_value_line_count: 'Zero value line count',
  review_line_count: 'Review line count',
  total_actual_commission_ex_gst: 'Actual Commission (ex GST)',
  total_theoretical_commission_ex_gst: 'Potential Commission (ex GST)',
  total_assistant_commission_ex_gst: 'Total assistant commission (ex GST)',
  unconfigured_paid_staff_line_count: 'Unconfigured paid staff line count',
  has_unconfigured_paid_staff_rows: 'Has unconfigured paid staff rows',
  user_id: 'User ID',
  access_role: 'Access role',
}

/**
 * Default visible middle columns (after fixed Week + Pay week start; Detail stays fixed).
 * Picker lists these first in this order; all other middle columns are off by default.
 */
const DEFAULT_VISIBLE_MIDDLE: readonly MiddleColumnId[] = [
  'pay_date',
  'pay_week_end',
  'location',
  'derived_staff_paid_full_name',
  'derived_staff_paid_remuneration_plan',
  'total_sales_ex_gst',
  'total_theoretical_commission_ex_gst',
  'total_actual_commission_ex_gst',
]

const DEFAULT_HIDDEN_MIDDLE: MiddleColumnId[] = ALL_MIDDLE_IDS.filter(
  (id) => !(DEFAULT_VISIBLE_MIDDLE as readonly string[]).includes(id),
)

/** Full picker order: default-visible columns first, then the rest (hidden by default). */
export const DEFAULT_MIDDLE_ORDER: MiddleColumnId[] = [
  ...DEFAULT_VISIBLE_MIDDLE,
  ...ALL_MIDDLE_IDS.filter((id) => !DEFAULT_VISIBLE_MIDDLE.includes(id)),
]

export type ColumnPreferences = {
  /** Order of middle columns (subset of MiddleColumnId). */
  order: MiddleColumnId[]
  /** Hidden middle columns (locked ids must never appear here when saving). */
  hidden: MiddleColumnId[]
}

export function defaultColumnPreferences(): ColumnPreferences {
  return {
    order: [...DEFAULT_MIDDLE_ORDER],
    hidden: [...DEFAULT_HIDDEN_MIDDLE],
  }
}

export function isMiddleColumnId(s: string): s is MiddleColumnId {
  return (ALL_MIDDLE_IDS as readonly string[]).includes(s)
}

export function parseStoredPreferences(raw: string | null): ColumnPreferences | null {
  if (raw == null || raw.trim() === '') return null
  try {
    const v = JSON.parse(raw) as unknown
    if (v == null || typeof v !== 'object') return null
    const orderRaw = (v as { order?: unknown }).order
    const hiddenRaw = (v as { hidden?: unknown }).hidden
    if (!Array.isArray(orderRaw)) return null
    const order = orderRaw.filter((x): x is MiddleColumnId =>
      typeof x === 'string' && isMiddleColumnId(x),
    )
    const hidden = Array.isArray(hiddenRaw)
      ? hiddenRaw.filter((x): x is MiddleColumnId =>
          typeof x === 'string' && isMiddleColumnId(x),
        )
      : []
    if (order.length === 0) return null
    // Merge in any new columns from ALL_MIDDLE_IDS not in order (append).
    const seen = new Set(order)
    for (const id of ALL_MIDDLE_IDS) {
      if (!seen.has(id)) order.push(id)
    }
    // Dedupe order
    const deduped: MiddleColumnId[] = []
    seen.clear()
    for (const id of order) {
      if (!seen.has(id)) {
        seen.add(id)
        deduped.push(id)
      }
    }
    const hiddenSet = new Set(hidden.filter((id) => !MIDDLE_LOCKED_VISIBLE.has(id)))
    return { order: deduped, hidden: [...hiddenSet] }
  } catch {
    return null
  }
}

export function loadColumnPreferences(): ColumnPreferences {
  if (typeof window === 'undefined') return defaultColumnPreferences()
  try {
    const parsed = parseStoredPreferences(
      window.localStorage.getItem(PAYROLL_SUMMARY_COLUMNS_STORAGE_KEY),
    )
    return parsed ?? defaultColumnPreferences()
  } catch {
    return defaultColumnPreferences()
  }
}

export function saveColumnPreferences(prefs: ColumnPreferences): void {
  if (typeof window === 'undefined') return
  const hidden = prefs.hidden.filter((id) => !MIDDLE_LOCKED_VISIBLE.has(id))
  try {
    window.localStorage.setItem(
      PAYROLL_SUMMARY_COLUMNS_STORAGE_KEY,
      JSON.stringify({ order: prefs.order, hidden }),
    )
  } catch {
    /* quota / private mode */
  }
}

/** Map logical column to row key for Cell; `null` if column not in this row. */
export function resolveRowKeyForMiddleColumn(
  id: MiddleColumnId,
  row: WeeklyCommissionSummaryRow,
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
  if (Object.prototype.hasOwnProperty.call(row, id)) return id
  return null
}

/** Visible middle columns in table order (for headers, cells, drag targets). */
export type VisibleMiddleColumn = { id: MiddleColumnId; rowKey: string }

export function visibleMiddleColumns(
  sample: WeeklyCommissionSummaryRow,
  prefs: ColumnPreferences,
): VisibleMiddleColumn[] {
  const hidden = new Set(
    prefs.hidden.filter((id) => !MIDDLE_LOCKED_VISIBLE.has(id)),
  )
  const out: VisibleMiddleColumn[] = []
  for (const id of prefs.order) {
    if (hidden.has(id)) continue
    const rk = resolveRowKeyForMiddleColumn(id, sample)
    if (rk != null) out.push({ id, rowKey: rk })
  }
  return out
}

/**
 * Middle data keys to render (respects order, hidden, RPC presence on `sample`).
 * Use one sample row (e.g. first row) for column headers; body cells use the same keys.
 */
export function middleRowKeysForPreferences(
  sample: WeeklyCommissionSummaryRow,
  prefs: ColumnPreferences,
): string[] {
  return visibleMiddleColumns(sample, prefs).map((c) => c.rowKey)
}

/** Move `fromId` to the index of `toId` in the full preference order (HTML5 DnD + picker). */
export function reorderMiddleColumnOrder(
  order: MiddleColumnId[],
  fromId: MiddleColumnId,
  toId: MiddleColumnId,
): MiddleColumnId[] {
  if (fromId === toId) return [...order]
  if (!order.includes(fromId) || !order.includes(toId)) return [...order]
  const without = order.filter((id) => id !== fromId)
  const insertAt = without.indexOf(toId)
  if (insertAt < 0) return [...order]
  const next = [...without]
  next.splice(insertAt, 0, fromId)
  return next
}
