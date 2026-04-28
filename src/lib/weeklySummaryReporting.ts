import type { WeeklySummaryExtraTile } from '@/features/payroll/components/WeeklySummaryStats'
import type { SalesDailySheetsDataSourceRow } from '@/features/payroll/types'

/** Rows that expose `pay_week_start` for date-range filtering. */
export type PayWeekDatedRow = {
  pay_week_start?: string | null
}

export type SalesExGstByLocationRow = PayWeekDatedRow & {
  location_id?: string | null
  total_sales_ex_gst?: number | string | null
}

/**
 * ISO `YYYY-MM-DD` for the earliest and latest `pay_week_start` across
 * the loaded summary rows.
 */
export function computeDateExtents(rows: PayWeekDatedRow[]): {
  min: string | null
  max: string | null
} {
  let min: string | null = null
  let max: string | null = null
  for (const r of rows) {
    const w = r.pay_week_start ? String(r.pay_week_start).trim() : ''
    if (!w) continue
    if (min == null || w < min) min = w
    if (max == null || w > max) max = w
  }
  return { min, max }
}

/**
 * Default `dateFrom` = one year before `dateMax`, clamped up to `dateMin`.
 */
export function defaultDateFromForRange(
  min: string | null,
  max: string | null,
): string {
  if (!max) return ''
  const m = new Date(`${max}T00:00:00Z`)
  if (Number.isNaN(m.getTime())) return min ?? ''
  m.setUTCFullYear(m.getUTCFullYear() - 1)
  let candidate = m.toISOString().slice(0, 10)
  if (min && candidate < min) candidate = min
  return candidate
}

export function filterRowsByPayWeekDateRange<T extends PayWeekDatedRow>(
  rows: T[],
  dateFrom: string,
  dateTo: string,
): T[] {
  if (!dateFrom && !dateTo) return rows
  return rows.filter((r) => {
    const w = r.pay_week_start ? String(r.pay_week_start).trim() : ''
    if (!w) return true
    if (dateFrom && w < dateFrom) return false
    if (dateTo && w > dateTo) return false
    return true
  })
}

/**
 * Per-location SALES (EX GST) tiles from SDS data sources + date-scoped
 * summary rows. Totals use `total_sales_ex_gst` summed by
 * `location_id`; labels use `locations.name` from the RPC (uppercased).
 */
export function buildPerLocationSalesExtraTiles(
  dataSources: SalesDailySheetsDataSourceRow[] | undefined,
  dateScopedRows: SalesExGstByLocationRow[],
): WeeklySummaryExtraTile[] {
  const sources = dataSources ?? []
  if (sources.length === 0) return []
  const sumByLocationId = new Map<string, number>()
  let foundAny = false
  for (const r of dateScopedRows) {
    const id = r.location_id ? String(r.location_id).trim() : ''
    if (!id) continue
    const v = r.total_sales_ex_gst
    if (v == null || v === '') continue
    const n = typeof v === 'number' ? v : Number(v)
    if (!Number.isFinite(n)) continue
    sumByLocationId.set(id, (sumByLocationId.get(id) ?? 0) + n)
    foundAny = true
  }
  return sources
    .filter((s) => s.location_id && String(s.location_id).trim() !== '')
    .map((s) => {
      const id = String(s.location_id).trim()
      const labelLocation =
        s.location_name && String(s.location_name).trim() !== ''
          ? String(s.location_name).trim().toUpperCase()
          : String(s.location_code ?? id).toUpperCase()
      return {
        key: `sales-ex-gst-${id}`,
        label: `Sales (ex GST) - ${labelLocation}`,
        value: foundAny ? sumByLocationId.get(id) ?? 0 : null,
      }
    })
}
