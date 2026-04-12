import type { AdminPayrollSummaryRow } from '@/features/admin/types'
import { locationLabelFromRow, type LocationFilterOption } from '@/lib/locationDisplay'
import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'

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

export function filterStylistSummaryRows(
  rows: WeeklyCommissionSummaryRow[],
  opts: { locationId: string; search: string },
): WeeklyCommissionSummaryRow[] {
  let out = rows
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
  opts: { locationId: string; search: string },
): AdminPayrollSummaryRow[] {
  let out = rows
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
