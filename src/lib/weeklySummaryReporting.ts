import type { WeeklySummaryExtraTile } from '@/features/payroll/components/WeeklySummaryStats'
import type { SalesDailySheetsDataSourceRow } from '@/features/payroll/types'

/** Normalise API date / timestamptz to `YYYY-MM-DD` for comparisons. */
export function isoDateOnly(value: string | null | undefined): string {
  if (value == null) return ''
  const t = String(value).trim()
  if (t.length >= 10 && /^\d{4}-\d{2}-\d{2}/.test(t)) return t.slice(0, 10)
  return t
}

/** Rows that expose pay week bounds for date-range filtering. */
export type PayWeekDatedRow = {
  pay_week_start?: string | null
  pay_week_end?: string | null
}

export type SalesExGstByLocationRow = PayWeekDatedRow & {
  location_id?: string | null
  total_sales_ex_gst?: number | string | null
}

function rowWeekStartIso(r: PayWeekDatedRow): string {
  return isoDateOnly(r.pay_week_start ?? null)
}

function rowWeekEndIso(r: PayWeekDatedRow): string {
  const end = isoDateOnly(r.pay_week_end ?? null)
  const start = rowWeekStartIso(r)
  return end || start
}

/**
 * Extents for date controls and filtering, aligned with underlying week
 * rows:
 * - `min` = earliest `pay_week_start` (Monday / start of first week).
 * - `max` = latest calendar day in the data: max of
 *   `coalesce(pay_week_end, pay_week_start)` so the default "to" date
 *   matches the newest week end (e.g. Sunday), not only the Monday.
 */
export function computeDateExtents(rows: PayWeekDatedRow[]): {
  min: string | null
  max: string | null
} {
  let min: string | null = null
  let max: string | null = null
  for (const r of rows) {
    const ws = rowWeekStartIso(r)
    if (!ws) continue
    if (min == null || ws < min) min = ws
    const we = rowWeekEndIso(r)
    if (max == null || we > max) max = we
  }
  return { min, max }
}

/**
 * Default `dateFrom` = one calendar year before `dateMax`, clamped up to
 * `min` (first available week start).
 */
export function defaultDateFromForRange(
  min: string | null,
  max: string | null,
): string {
  if (!max) return ''
  const m = new Date(`${max}T12:00:00Z`)
  if (Number.isNaN(m.getTime())) return min ?? ''
  m.setUTCFullYear(m.getUTCFullYear() - 1)
  let candidate = m.toISOString().slice(0, 10)
  if (min && candidate < min) candidate = min
  return candidate
}

/**
 * Include a row if its pay week overlaps `[dateFrom, dateTo]` (inclusive
 * ISO dates). Uses `pay_week_end` when present so the range aligns with
 * the same basis as {@link computeDateExtents}'s `max`.
 */
export function filterRowsByPayWeekDateRange<T extends PayWeekDatedRow>(
  rows: T[],
  dateFrom: string,
  dateTo: string,
): T[] {
  if (!dateFrom && !dateTo) return rows
  return rows.filter((r) => {
    const ws = rowWeekStartIso(r)
    const we = rowWeekEndIso(r)
    if (!ws && !we) return true
    const wstart = ws || we
    const wend = we || ws
    if (dateFrom && wend < dateFrom) return false
    if (dateTo && wstart > dateTo) return false
    return true
  })
}

/**
 * Latest inclusive `pay_week_end` among rows for this `pay_week_start`
 * (falls back to start when end is missing).
 */
export function payWeekInclusiveEndForStart<T extends PayWeekDatedRow>(
  rows: T[],
  payWeekStartIso: string,
): string {
  const want = isoDateOnly(payWeekStartIso)
  if (!want) return ''
  let bestEnd = ''
  for (const r of rows) {
    const ws = rowWeekStartIso(r)
    if (ws !== want) continue
    const we = rowWeekEndIso(r)
    if (we > bestEnd || bestEnd === '') bestEnd = we
  }
  return bestEnd || want
}

/**
 * If `[fromIso, toIso]` equals some row's pay week window exactly,
 * return that week's `pay_week_start`; otherwise `null`.
 */
export function payWeekStartIfRangeIsExactlyOnePayWeek<
  T extends PayWeekDatedRow,
>(rows: T[], fromIso: string, toIso: string): string | null {
  const a = isoDateOnly(fromIso)
  const b = isoDateOnly(toIso)
  if (!a || !b) return null
  for (const r of rows) {
    const ws = rowWeekStartIso(r)
    const we = rowWeekEndIso(r)
    if (!ws) continue
    if (ws === a && we === b) return ws
  }
  return null
}

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

/**
 * Sum `total_sales_ex_gst` across all rows (all locations). Uses the
 * same row set as {@link buildPerLocationSalesExtraTiles} (typically
 * `dateScopedRows`) so the total card matches the per-location tiles.
 */
export function sumTotalSalesExGstFromRows(
  rows: SalesExGstByLocationRow[],
): number | null {
  let total = 0
  let found = false
  for (const r of rows) {
    const v = r.total_sales_ex_gst
    if (v == null || v === '') continue
    const n = typeof v === 'number' ? v : Number(v)
    if (!Number.isFinite(n)) continue
    total += n
    found = true
  }
  return found ? total : null
}
