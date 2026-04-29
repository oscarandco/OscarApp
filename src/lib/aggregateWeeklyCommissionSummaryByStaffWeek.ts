import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { comparePayWeekStartDesc } from '@/lib/payrollSorting'

function parseFiniteNumber(v: unknown): number | null {
  if (v == null || v === '') return null
  const n = typeof v === 'number' ? v : Number(v)
  return Number.isFinite(n) ? n : null
}

function addNumeric(a: unknown, b: unknown): unknown {
  const na = parseFiniteNumber(a)
  const nb = parseFiniteNumber(b)
  if (na == null && nb == null) return null
  return (na ?? 0) + (nb ?? 0)
}

function rowLineCount(r: WeeklyCommissionSummaryRow): number {
  const lc = parseFiniteNumber(r.line_count)
  if (lc != null) return lc
  const rc = parseFiniteNumber(r.row_count)
  return rc ?? 0
}

function staffWeekGroupKey(r: WeeklyCommissionSummaryRow): string {
  const w = String(r.pay_week_start ?? '').trim()
  const id = String(r.derived_staff_paid_id ?? '').trim()
  if (id !== '') return `${w}\t${id}`
  const disp = String(r.derived_staff_paid_display_name ?? '').trim().toLowerCase()
  const full = String(r.derived_staff_paid_full_name ?? '').trim().toLowerCase()
  return `${w}\tname:${disp}|${full}`
}

function mergeGroup(group: WeeklyCommissionSummaryRow[]): WeeklyCommissionSummaryRow {
  const sorted = [...group].sort((a, b) => {
    const la = String(a.location_id ?? '')
    const lb = String(b.location_id ?? '')
    return la.localeCompare(lb, undefined, { numeric: true })
  })
  const base = { ...sorted[0] } as WeeklyCommissionSummaryRow

  const distinctLocs = new Set(
    sorted.map((r) => String(r.location_id ?? '').trim()).filter(Boolean),
  )
  if (distinctLocs.size === 1) {
    const id = [...distinctLocs][0]
    base.location_id = id
    const nameRow = sorted.find((r) => String(r.location_id ?? '').trim() === id)
    base.location_name =
      nameRow?.location_name != null && String(nameRow.location_name).trim() !== ''
        ? String(nameRow.location_name).trim()
        : id
  } else {
    base.location_id = null
    base.location_name = 'All locations'
  }

  let lineSum = 0
  for (const r of sorted) {
    lineSum += rowLineCount(r)
  }
  base.line_count = lineSum
  base.row_count = lineSum

  const numericKeys: (keyof WeeklyCommissionSummaryRow)[] = [
    'payable_line_count',
    'expected_no_commission_line_count',
    'zero_value_line_count',
    'review_line_count',
    'total_sales_ex_gst',
    'total_theoretical_commission_ex_gst',
    'unconfigured_paid_staff_line_count',
  ]
  for (const k of numericKeys) {
    let acc: unknown = null
    for (const r of sorted) {
      acc = acc == null ? r[k] : addNumeric(acc, r[k])
    }
    base[k] = acc as WeeklyCommissionSummaryRow[typeof k]
  }

  let actualSum = 0
  let hasActual = false
  for (const r of sorted) {
    const v = r.total_actual_commission_ex_gst ?? r.total_actual_commission
    const n = parseFiniteNumber(v)
    if (n != null) {
      actualSum += n
      hasActual = true
    }
  }
  if (hasActual) {
    base.total_actual_commission_ex_gst = actualSum
    base.total_actual_commission = actualSum
  }

  let asstSum = 0
  let hasAsst = false
  for (const r of sorted) {
    const v = r.total_assistant_commission_ex_gst ?? r.total_assistant_commission
    const n = parseFiniteNumber(v)
    if (n != null) {
      asstSum += n
      hasAsst = true
    }
  }
  if (hasAsst) {
    base.total_assistant_commission_ex_gst = asstSum
    base.total_assistant_commission = asstSum
  }

  base.has_unconfigured_paid_staff_rows = sorted.some(
    (r) => r.has_unconfigured_paid_staff_rows === true,
  )

  const workParts = new Set<string>()
  for (const r of sorted) {
    const w = r.work_performed_by
    if (w == null || String(w).trim() === '') continue
    for (const part of String(w).split(',')) {
      const t = part.trim()
      if (t !== '') workParts.add(t)
    }
  }
  if (workParts.size > 0) {
    base.work_performed_by = [...workParts].sort((a, b) =>
      a.localeCompare(b, undefined, { sensitivity: 'base' }),
    ).join(', ')
  }

  return base
}

function sortDisplayRows(rows: WeeklyCommissionSummaryRow[]): WeeklyCommissionSummaryRow[] {
  return [...rows].sort((a, b) => {
    const w = comparePayWeekStartDesc(a.pay_week_start, b.pay_week_start)
    if (w !== 0) return w
    const la = String(a.location_id ?? '')
    const lb = String(b.location_id ?? '')
    if (la !== lb) return la.localeCompare(lb, undefined, { numeric: true })
    const da = String(a.derived_staff_paid_display_name ?? '').toLowerCase()
    const db = String(b.derived_staff_paid_display_name ?? '').toLowerCase()
    return da.localeCompare(db, undefined, { sensitivity: 'base' })
  })
}

/**
 * One row per pay week × paid staff, summing measures across all locations.
 */
export function aggregateWeeklyCommissionSummaryByStaffWeek(
  rows: WeeklyCommissionSummaryRow[],
): WeeklyCommissionSummaryRow[] {
  const map = new Map<string, WeeklyCommissionSummaryRow[]>()
  for (const r of rows) {
    const k = staffWeekGroupKey(r)
    const list = map.get(k) ?? []
    list.push(r)
    map.set(k, list)
  }
  const out: WeeklyCommissionSummaryRow[] = []
  for (const group of map.values()) {
    out.push(mergeGroup(group))
  }
  return sortDisplayRows(out)
}
