import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'

export const PAYROLL_SUMMARY_COLUMNS_STORAGE_KEY = 'payroll-summary-columns'

/** Middle data columns (between Week / Pay week start and Detail). */
export type MiddleColumnId =
  | 'pay_week_end'
  | 'pay_date'
  | 'location'
  | 'derived_staff_paid_display_name'
  | 'total_sales_ex_gst'
  | 'row_count'
  | 'payable_line_count'
  | 'expected_no_commission_line_count'
  | 'unconfigured_paid_staff_line_count'
  | 'has_unconfigured_paid_staff_rows'

const ALL_MIDDLE_IDS: readonly MiddleColumnId[] = [
  'pay_week_end',
  'pay_date',
  'location',
  'derived_staff_paid_display_name',
  'total_sales_ex_gst',
  'row_count',
  'payable_line_count',
  'expected_no_commission_line_count',
  'unconfigured_paid_staff_line_count',
  'has_unconfigured_paid_staff_rows',
]

/** Ids that cannot be hidden (still participate in ordering). */
export const MIDDLE_LOCKED_VISIBLE: ReadonlySet<MiddleColumnId> = new Set([
  'pay_date',
])

export const COLUMN_LABEL: Record<MiddleColumnId, string> = {
  pay_week_end: 'Pay week end',
  pay_date: 'Pay date',
  location: 'Location',
  derived_staff_paid_display_name: 'Derived staff paid display name',
  total_sales_ex_gst: 'Total sales ex GST',
  row_count: 'Line count',
  payable_line_count: 'Payable line count',
  expected_no_commission_line_count: 'Expected no commission line count',
  unconfigured_paid_staff_line_count: 'Unconfigured paid staff line count',
  has_unconfigured_paid_staff_rows: 'Has unconfigured paid staff rows',
}

/** Default order and visibility (all middle columns on except those absent from row later). */
export const DEFAULT_MIDDLE_ORDER: MiddleColumnId[] = [...ALL_MIDDLE_IDS]

export type ColumnPreferences = {
  /** Order of middle columns (subset of MiddleColumnId). */
  order: MiddleColumnId[]
  /** Hidden middle columns (locked ids must never appear here when saving). */
  hidden: MiddleColumnId[]
}

export function defaultColumnPreferences(): ColumnPreferences {
  return {
    order: [...DEFAULT_MIDDLE_ORDER],
    hidden: [],
  }
}

function isMiddleColumnId(s: string): s is MiddleColumnId {
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
  if (Object.prototype.hasOwnProperty.call(row, id)) return id
  return null
}

/**
 * Middle data keys to render (respects order, hidden, RPC presence on `sample`).
 * Use one sample row (e.g. first row) for column headers; body cells use the same keys.
 */
export function middleRowKeysForPreferences(
  sample: WeeklyCommissionSummaryRow,
  prefs: ColumnPreferences,
): string[] {
  const hidden = new Set(
    prefs.hidden.filter((id) => !MIDDLE_LOCKED_VISIBLE.has(id)),
  )
  const out: string[] = []
  for (const id of prefs.order) {
    if (hidden.has(id)) continue
    const rk = resolveRowKeyForMiddleColumn(id, sample)
    if (rk != null) out.push(rk)
  }
  return out
}
