/**
 * Column prefs for the weekly **line detail** table (`/app/my-sales/:week`, PayrollLineTable).
 * Storage: `payroll-line-columns`. Summary table uses `weeklySummaryTableColumns` separately.
 */
import type { WeeklyCommissionLineRow } from '@/features/payroll/types'

export const PAYROLL_LINE_COLUMNS_STORAGE_KEY = 'payroll-line-columns'

/** Configurable line-level columns (full table is driven by prefs). */
export type LineColumnId =
  | 'invoice'
  | 'sale_date'
  | 'sale_datetime'
  | 'pay_week_start'
  | 'pay_week_end'
  | 'pay_date'
  | 'customer_name'
  | 'product_service_name'
  | 'product_type_actual'
  | 'product_type_short'
  | 'commission_product_service'
  | 'commission_category_final'
  | 'quantity'
  | 'price_ex_gst'
  | 'price_incl_gst'
  | 'derived_staff_paid_id'
  | 'derived_staff_paid_display_name'
  | 'derived_staff_paid_full_name'
  | 'actual_commission_rate'
  | 'actual_commission_amt_ex_gst'
  | 'assistant_commission_amt_ex_gst'
  | 'payroll_status'
  | 'stylist_visible_note'
  | 'location'
  | 'access_role'
  | 'user_id'
  | 'id'
  | 'import_batch_id'
  | 'raw_row_id'
  | 'day_name'
  | 'month_start'
  | 'month_num'

const ALL_LINE_IDS: readonly LineColumnId[] = [
  'invoice',
  'sale_date',
  'sale_datetime',
  'pay_week_start',
  'pay_week_end',
  'pay_date',
  'customer_name',
  'product_service_name',
  'product_type_actual',
  'product_type_short',
  'commission_product_service',
  'commission_category_final',
  'quantity',
  'price_ex_gst',
  'price_incl_gst',
  'derived_staff_paid_id',
  'derived_staff_paid_display_name',
  'derived_staff_paid_full_name',
  'actual_commission_rate',
  'actual_commission_amt_ex_gst',
  'assistant_commission_amt_ex_gst',
  'payroll_status',
  'stylist_visible_note',
  'location',
  'access_role',
  'user_id',
  'id',
  'import_batch_id',
  'raw_row_id',
  'day_name',
  'month_start',
  'month_num',
]

export const LINE_LOCKED_VISIBLE: ReadonlySet<LineColumnId> = new Set(['invoice'])

export const LINE_COLUMN_LABEL: Record<LineColumnId, string> = {
  invoice: 'Invoice',
  sale_date: 'Sale date',
  sale_datetime: 'Sale date/time',
  pay_week_start: 'Pay week start',
  pay_week_end: 'Pay week end',
  pay_date: 'Pay date',
  customer_name: 'Customer',
  product_service_name: 'Product / service',
  product_type_actual: 'Commission product type (actual)',
  product_type_short: 'Product type (short)',
  commission_product_service: 'Actual commission product/service',
  commission_category_final: 'Commission category',
  quantity: 'Quantity',
  price_ex_gst: 'Price ex GST',
  price_incl_gst: 'Price incl GST',
  derived_staff_paid_id: 'Staff paid ID',
  derived_staff_paid_display_name: 'Staff paid (display)',
  derived_staff_paid_full_name: 'Staff paid (full name)',
  actual_commission_rate: 'Actual commission rate',
  actual_commission_amt_ex_gst: 'Actual commission (ex GST)',
  assistant_commission_amt_ex_gst: 'Assistant commission (ex GST)',
  payroll_status: 'Payroll status',
  stylist_visible_note: 'Stylist note',
  location: 'Location',
  access_role: 'Access role',
  user_id: 'User ID',
  id: 'Row ID',
  import_batch_id: 'Import batch ID',
  raw_row_id: 'Raw row ID',
  day_name: 'Day name',
  month_start: 'Month start',
  month_num: 'Month #',
}

/** Default visible columns (top of table and Columns menu); all others off until toggled or Reset. */
const DEFAULT_VISIBLE_LINE: readonly LineColumnId[] = [
  'pay_week_start',
  'location',
  'invoice',
  'sale_date',
  'pay_week_end',
  'customer_name',
  'derived_staff_paid_full_name',
  'product_service_name',
  'price_ex_gst',
  'price_incl_gst',
  'quantity',
  'actual_commission_rate',
  'actual_commission_amt_ex_gst',
  'commission_product_service',
  'product_type_actual',
  'commission_category_final',
]

const DEFAULT_HIDDEN_LINE: LineColumnId[] = ALL_LINE_IDS.filter(
  (id) => !(DEFAULT_VISIBLE_LINE as readonly string[]).includes(id),
)

/** Full menu order: defaults first, then remaining ids in stable ALL_LINE_IDS order. */
export const DEFAULT_LINE_ORDER: LineColumnId[] = [
  ...DEFAULT_VISIBLE_LINE,
  ...ALL_LINE_IDS.filter((id) => !DEFAULT_VISIBLE_LINE.includes(id)),
]

export type LineTablePreferences = {
  order: LineColumnId[]
  hidden: LineColumnId[]
}

export function defaultLineTablePreferences(): LineTablePreferences {
  return {
    order: [...DEFAULT_LINE_ORDER],
    hidden: [...DEFAULT_HIDDEN_LINE],
  }
}

export function isLineColumnId(s: string): s is LineColumnId {
  return (ALL_LINE_IDS as readonly string[]).includes(s)
}

export function parseLineTablePreferences(raw: string | null): LineTablePreferences | null {
  if (raw == null || raw.trim() === '') return null
  try {
    const v = JSON.parse(raw) as unknown
    if (v == null || typeof v !== 'object') return null
    const orderRaw = (v as { order?: unknown }).order
    const hiddenRaw = (v as { hidden?: unknown }).hidden
    if (!Array.isArray(orderRaw)) return null
    const order = orderRaw.filter((x): x is LineColumnId =>
      typeof x === 'string' && isLineColumnId(x),
    )
    const hidden = Array.isArray(hiddenRaw)
      ? hiddenRaw.filter((x): x is LineColumnId =>
          typeof x === 'string' && isLineColumnId(x),
        )
      : []
    if (order.length === 0) return null
    const seen = new Set(order)
    for (const id of ALL_LINE_IDS) {
      if (!seen.has(id)) order.push(id)
    }
    const deduped: LineColumnId[] = []
    seen.clear()
    for (const id of order) {
      if (!seen.has(id)) {
        seen.add(id)
        deduped.push(id)
      }
    }
    const hiddenSet = new Set(hidden.filter((id) => !LINE_LOCKED_VISIBLE.has(id)))
    return { order: deduped, hidden: [...hiddenSet] }
  } catch {
    return null
  }
}

export function loadLineTablePreferences(): LineTablePreferences {
  if (typeof window === 'undefined') return defaultLineTablePreferences()
  try {
    const parsed = parseLineTablePreferences(
      window.localStorage.getItem(PAYROLL_LINE_COLUMNS_STORAGE_KEY),
    )
    return parsed ?? defaultLineTablePreferences()
  } catch {
    return defaultLineTablePreferences()
  }
}

export function saveLineTablePreferences(prefs: LineTablePreferences): void {
  if (typeof window === 'undefined') return
  const hidden = prefs.hidden.filter((id) => !LINE_LOCKED_VISIBLE.has(id))
  try {
    window.localStorage.setItem(
      PAYROLL_LINE_COLUMNS_STORAGE_KEY,
      JSON.stringify({ order: prefs.order, hidden }),
    )
  } catch {
    /* quota / private mode */
  }
}

export function resolveRowKeyForLineColumn(
  id: LineColumnId,
  row: WeeklyCommissionLineRow,
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
  if (id === 'actual_commission_amt_ex_gst') {
    if (Object.prototype.hasOwnProperty.call(row, 'actual_commission_amt_ex_gst')) {
      return 'actual_commission_amt_ex_gst'
    }
    if (Object.prototype.hasOwnProperty.call(row, 'actual_commission_amount')) {
      return 'actual_commission_amount'
    }
    return null
  }
  if (id === 'assistant_commission_amt_ex_gst') {
    if (Object.prototype.hasOwnProperty.call(row, 'assistant_commission_amt_ex_gst')) {
      return 'assistant_commission_amt_ex_gst'
    }
    if (Object.prototype.hasOwnProperty.call(row, 'assistant_commission_amount')) {
      return 'assistant_commission_amount'
    }
    return null
  }
  if (Object.prototype.hasOwnProperty.call(row, id)) return id
  return null
}

export type VisibleLineColumn = { id: LineColumnId; rowKey: string }

export function visibleLineColumns(
  sample: WeeklyCommissionLineRow,
  prefs: LineTablePreferences,
): VisibleLineColumn[] {
  const hidden = new Set(
    prefs.hidden.filter((id) => !LINE_LOCKED_VISIBLE.has(id)),
  )
  const out: VisibleLineColumn[] = []
  for (const id of prefs.order) {
    if (hidden.has(id)) continue
    const rk = resolveRowKeyForLineColumn(id, sample)
    if (rk != null) out.push({ id, rowKey: rk })
  }
  return out
}

export function lineRowKeysForPreferences(
  sample: WeeklyCommissionLineRow,
  prefs: LineTablePreferences,
): string[] {
  return visibleLineColumns(sample, prefs).map((c) => c.rowKey)
}

export function reorderLineColumnOrder(
  order: LineColumnId[],
  fromId: LineColumnId,
  toId: LineColumnId,
): LineColumnId[] {
  if (fromId === toId) return [...order]
  if (!order.includes(fromId) || !order.includes(toId)) return [...order]
  const without = order.filter((id) => id !== fromId)
  const insertAt = without.indexOf(toId)
  if (insertAt < 0) return [...order]
  const next = [...without]
  next.splice(insertAt, 0, fromId)
  return next
}
