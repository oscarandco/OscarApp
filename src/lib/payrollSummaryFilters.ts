import type { AdminPayrollSummaryRow } from '@/features/admin/types'
import { locationLabelFromRow, type LocationFilterOption } from '@/lib/locationDisplay'
import type {
  WeeklyCommissionLineRow,
  WeeklyCommissionSummaryRow,
} from '@/features/payroll/types'
import { formatDateLabel } from '@/lib/formatters'
import { comparePayWeekStartDesc } from '@/lib/payrollSorting'

/** Distinct locations for filter dropdown: id + human label when `location_name` is present on any row. */
export function uniqueLocationOptions<
  T extends {
    location_id?: string | null
    location_name?: string | null
  },
>(rows: T[]): LocationFilterOption[] {
  const ids = new Set<string>()
  for (const r of rows) {
    const id = r.location_id
    if (id != null && String(id).trim() !== '') ids.add(String(id).trim())
  }
  const out: LocationFilterOption[] = []
  for (const id of [...ids].sort((a, b) => a.localeCompare(b, undefined, { numeric: true }))) {
    const rowWithName = rows.find(
      (r) =>
        String(r.location_id ?? '').trim() === id &&
        r.location_name != null &&
        String(r.location_name).trim() !== '',
    )
    const label = rowWithName
      ? String(rowWithName.location_name).trim()
      : locationLabelFromRow({ location_id: id })
    out.push({ id, label: label !== '—' ? label : id })
  }
  return out.sort((a, b) =>
    a.label.localeCompare(b.label, undefined, { sensitivity: 'base' }),
  )
}

/** Distinct pay week starts (newest first) with display labels for filter dropdowns. */
export type PayWeekStartFilterOption = { value: string; label: string }

export function uniquePayWeekStartOptions<
  T extends { pay_week_start?: string | null },
>(rows: T[]): PayWeekStartFilterOption[] {
  const seen = new Set<string>()
  for (const r of rows) {
    const w = r.pay_week_start
    if (w != null && String(w).trim() !== '') seen.add(String(w).trim())
  }
  const values = [...seen].sort((a, b) => comparePayWeekStartDesc(a, b))
  return values.map((value) => ({
    value,
    label: formatDateLabel(value),
  }))
}

/** Client-side filters for weekly line detail (single week; no pay-week filter). */
export function filterLineRows(
  rows: WeeklyCommissionLineRow[],
  opts: { locationId: string; search: string },
): WeeklyCommissionLineRow[] {
  let out = rows
  if (opts.locationId) {
    out = out.filter((r) => String(r.location_id ?? '') === opts.locationId)
  }
  const q = opts.search.trim().toLowerCase()
  if (q) {
    out = out.filter((r) => {
      const parts = [
        r.derived_staff_paid_display_name,
        r.customer_name,
        r.invoice,
        r.product_service_name,
      ]
      return parts.some(
        (p) =>
          p != null &&
          String(p).trim() !== '' &&
          String(p).toLowerCase().includes(q),
      )
    })
  }
  return out
}

/**
 * Narrow weekly line rows to those matching one summary row (week + location + staff).
 * Prefer `derived_staff_paid_id` when present on both sides; otherwise match display/full name.
 */
export function filterCommissionLinesForSummaryRow(
  summary: WeeklyCommissionSummaryRow,
  lines: WeeklyCommissionLineRow[],
): WeeklyCommissionLineRow[] {
  const pw = String(summary.pay_week_start ?? '').trim()
  const loc = String(summary.location_id ?? '').trim()
  const staffId = String(summary.derived_staff_paid_id ?? '').trim()

  const disp = String(summary.derived_staff_paid_display_name ?? '').trim().toLowerCase()
  const full = String(summary.derived_staff_paid_full_name ?? '').trim().toLowerCase()

  return lines.filter((l) => {
    if (String(l.pay_week_start ?? '').trim() !== pw) return false
    if (String(l.location_id ?? '').trim() !== loc) return false

    if (staffId !== '') {
      const lid = String(l.derived_staff_paid_id ?? '').trim()
      if (lid === staffId) return true
    }

    const ld = String(l.derived_staff_paid_display_name ?? '').trim().toLowerCase()
    const lf = String(l.derived_staff_paid_full_name ?? '').trim().toLowerCase()

    if (disp !== '' && (ld === disp || lf === disp)) return true
    if (full !== '' && (ld === full || lf === full)) return true

    if (staffId === '' && disp === '' && full === '') return true
    return false
  })
}

/**
 * Admin weekly dashboard: lines for one pay week and one paid staff member (all locations).
 * Prefer `derived_staff_paid_id`; otherwise match dashboard `staffLabel` to line full/display name.
 * Unassigned dashboard row (`staffLabel` "—") matches lines with no paid staff id.
 */
export function filterAdminPayrollLinesForStaffWeek(
  lines: WeeklyCommissionLineRow[],
  opts: {
    payWeekStart: string
    derivedStaffPaidId: string | null
    staffLabel: string
  },
): WeeklyCommissionLineRow[] {
  const pw = String(opts.payWeekStart).trim()
  const idWanted =
    opts.derivedStaffPaidId != null && String(opts.derivedStaffPaidId).trim() !== ''
      ? String(opts.derivedStaffPaidId).trim()
      : ''
  const label = String(opts.staffLabel).trim()
  const labelLower = label.toLowerCase()

  return lines.filter((l) => {
    if (String(l.pay_week_start ?? '').trim() !== pw) return false

    if (idWanted !== '') {
      return String(l.derived_staff_paid_id ?? '').trim() === idWanted
    }

    if (label === '—') {
      return String(l.derived_staff_paid_id ?? '').trim() === ''
    }

    const ld = String(l.derived_staff_paid_display_name ?? '').trim().toLowerCase()
    const lf = String(l.derived_staff_paid_full_name ?? '').trim().toLowerCase()
    if (labelLower === '') return false
    return ld === labelLower || lf === labelLower
  })
}

export function filterStylistSummaryRows(
  rows: WeeklyCommissionSummaryRow[],
  opts: { locationId: string; search: string; payWeekStart?: string },
): WeeklyCommissionSummaryRow[] {
  let out = rows
  if (opts.payWeekStart?.trim()) {
    const wk = opts.payWeekStart.trim()
    out = out.filter((r) => String(r.pay_week_start ?? '').trim() === wk)
  }
  if (opts.locationId) {
    out = out.filter((r) => String(r.location_id ?? '') === opts.locationId)
  }
  const q = opts.search.trim().toLowerCase()
  if (q) {
    out = out.filter((r) => {
      const name = r.derived_staff_paid_display_name
      if (name == null || String(name).trim() === '') return false
      return String(name).toLowerCase().includes(q)
    })
  }
  return out
}

export function filterAdminSummaryRows(
  rows: AdminPayrollSummaryRow[],
  opts: { locationId: string; search: string; payWeekStart?: string },
): AdminPayrollSummaryRow[] {
  let out = rows
  if (opts.payWeekStart?.trim()) {
    const wk = opts.payWeekStart.trim()
    out = out.filter((r) => String(r.pay_week_start ?? '').trim() === wk)
  }
  if (opts.locationId) {
    out = out.filter((r) => String(r.location_id ?? '') === opts.locationId)
  }
  const q = opts.search.trim().toLowerCase()
  if (q) {
    out = out.filter((r) => {
      const parts = [r.derived_staff_paid_display_name, r.staff_full_name]
      return parts.some(
        (p) =>
          p != null &&
          String(p).trim() !== '' &&
          String(p).toLowerCase().includes(q),
      )
    })
  }
  return out
}
