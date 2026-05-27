import { useMemo, useState } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import {
  StaffTrendsLineChart,
  type StaffTrendsSeries,
} from '@/features/admin/components/StaffTrendsLineChart'
import { StaffTrendsStaffPicker } from '@/features/admin/components/StaffTrendsStaffPicker'
import { useAdminPayrollSummaryWeekly } from '@/features/admin/hooks/useAdminPayrollSummaryWeekly'
import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { aggregateWeeklyCommissionSummaryByStaffWeek } from '@/lib/aggregateWeeklyCommissionSummaryByStaffWeek'
import { formatNzd } from '@/lib/formatters'
import { uniqueLocationOptions } from '@/lib/payrollSummaryFilters'
import { queryErrorDetail } from '@/lib/queryError'

/* ------------------------------------------------------------------ */
/* Series colours: 12 distinct, accessible colours; cycle if exceeded. */
/* ------------------------------------------------------------------ */
const SERIES_COLORS = [
  '#7c3aed', // violet-600
  '#0ea5e9', // sky-500
  '#16a34a', // green-600
  '#f59e0b', // amber-500
  '#ef4444', // red-500
  '#0891b2', // cyan-600
  '#db2777', // pink-600
  '#65a30d', // lime-600
  '#9333ea', // purple-600
  '#0d9488', // teal-600
  '#ea580c', // orange-600
  '#475569', // slate-600
]

/* ------------------------------------------------------------------ */
/* Date helpers (Monday-Sunday pay weeks, UTC to avoid TZ shifts).    */
/* Mirrors the view's ISO-weekday math.                                */
/* ------------------------------------------------------------------ */

function toIsoDate(d: Date): string {
  const y = d.getUTCFullYear()
  const m = String(d.getUTCMonth() + 1).padStart(2, '0')
  const day = String(d.getUTCDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

function parseUtcDate(iso: string): Date | null {
  if (!iso || !/^\d{4}-\d{2}-\d{2}/.test(iso)) return null
  const d = new Date(`${iso.substring(0, 10)}T00:00:00Z`)
  return Number.isNaN(d.getTime()) ? null : d
}

/** Monday of the ISO week containing `d` (UTC). */
function payWeekStartFor(d: Date): Date {
  // getUTCDay: Sun=0..Sat=6. ISO weekday: Mon=1..Sun=7.
  const isoDow = ((d.getUTCDay() + 6) % 7) + 1 // 1..7
  const monday = new Date(d.getTime())
  monday.setUTCDate(d.getUTCDate() - (isoDow - 1))
  monday.setUTCHours(0, 0, 0, 0)
  return monday
}

function addDays(d: Date, days: number): Date {
  const out = new Date(d.getTime())
  out.setUTCDate(out.getUTCDate() + days)
  return out
}

/** Generate the last N Monday week starts ending at `mostRecentMonday`. */
function buildWeekStartList(mostRecentMonday: Date, weeks: number): string[] {
  const out: string[] = []
  for (let i = weeks - 1; i >= 0; i--) {
    out.push(toIsoDate(addDays(mostRecentMonday, -7 * i)))
  }
  return out
}

function formatWeekLong(iso: string): string {
  const d = parseUtcDate(iso)
  if (!d) return iso
  return d.toLocaleDateString('en-NZ', {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    year: 'numeric',
    timeZone: 'UTC',
  })
}

/* ------------------------------------------------------------------ */
/* Row helpers                                                          */
/* ------------------------------------------------------------------ */

function parseNumOr0(v: unknown): number {
  if (v == null || v === '') return 0
  const n = typeof v === 'number' ? v : Number(v)
  return Number.isFinite(n) ? n : 0
}

function staffKey(r: WeeklyCommissionSummaryRow): {
  id: string
  label: string
} | null {
  const id = String(r.derived_staff_paid_id ?? '').trim()
  const display = String(r.derived_staff_paid_display_name ?? '').trim()
  const full = String(r.derived_staff_paid_full_name ?? '').trim()
  if (id === '' && display === '' && full === '') return null
  const label = display !== '' ? display : full !== '' ? full : '(Unknown)'
  return { id: id !== '' ? id : `name:${label.toLowerCase()}`, label }
}

/* ------------------------------------------------------------------ */
/* Page                                                                 */
/* ------------------------------------------------------------------ */

const WEEKS = 52

type SeriesGroup = {
  staffId: string
  staffName: string
  color: string
  sales: number[]
  potential: number[]
  actual: number[]
}

type TableRow = {
  payWeekStart: string
  staffId: string
  staffName: string
  sales: number
  potential: number
  actual: number
}

export function StaffTrendsPage() {
  const { data, isLoading, isError, error, refetch } =
    useAdminPayrollSummaryWeekly()

  const [selectedStaffIds, setSelectedStaffIds] = useState<string[]>([])
  const [locationId, setLocationId] = useState('')

  const sourceRows = data ?? []

  /* Compute the most recent Monday (so the chart's right edge is the
   * current pay week even if no sales have landed yet). */
  const mostRecentMonday = useMemo(() => payWeekStartFor(new Date()), [])
  const weekStarts = useMemo(
    () => buildWeekStartList(mostRecentMonday, WEEKS),
    [mostRecentMonday],
  )
  const weekStartSet = useMemo(() => new Set(weekStarts), [weekStarts])

  /* Scope rows to the 52-week window first. Location filter is applied
   * before staff-week aggregation so that "Auckland only" sums match
   * the Sales Summary page's behaviour when the user narrows location. */
  const scopedRows = useMemo(() => {
    const out: WeeklyCommissionSummaryRow[] = []
    for (const r of sourceRows) {
      const w = String(r.pay_week_start ?? '').trim()
      if (!weekStartSet.has(w)) continue
      if (locationId !== '' && String(r.location_id ?? '') !== locationId) continue
      out.push(r)
    }
    return out
  }, [sourceRows, weekStartSet, locationId])

  /* Reuse the existing helper: one row per (week, staff), summing across
   * locations. Same attribution as Sales Summary (derived_staff_paid_*). */
  const staffWeekRows = useMemo(
    () => aggregateWeeklyCommissionSummaryByStaffWeek(scopedRows),
    [scopedRows],
  )

  /* Staff filter options come from the data set (across all 52 weeks,
   * ignoring the staff-selection filter so the list is stable). */
  const staffOptions = useMemo(() => {
    const map = new Map<string, string>()
    for (const r of sourceRows) {
      const w = String(r.pay_week_start ?? '').trim()
      if (!weekStartSet.has(w)) continue
      if (locationId !== '' && String(r.location_id ?? '') !== locationId) continue
      const sk = staffKey(r)
      if (!sk) continue
      if (!map.has(sk.id)) map.set(sk.id, sk.label)
    }
    return [...map.entries()]
      .map(([id, label]) => ({ id, label }))
      .sort((a, b) =>
        a.label.localeCompare(b.label, undefined, { sensitivity: 'base' }),
      )
  }, [sourceRows, weekStartSet, locationId])

  const locationOptions = useMemo(
    () => uniqueLocationOptions(sourceRows),
    [sourceRows],
  )

  /* Build per-staff series (zero-filled across the 52-week window). */
  const seriesGroups = useMemo<SeriesGroup[]>(() => {
    if (selectedStaffIds.length === 0) return []
    const weekIndex = new Map<string, number>()
    weekStarts.forEach((w, i) => weekIndex.set(w, i))

    const groups = new Map<string, SeriesGroup>()
    selectedStaffIds.forEach((id, idx) => {
      const opt = staffOptions.find((s) => s.id === id)
      const name = opt?.label ?? '(Unknown)'
      groups.set(id, {
        staffId: id,
        staffName: name,
        color: SERIES_COLORS[idx % SERIES_COLORS.length],
        sales: new Array(WEEKS).fill(0),
        potential: new Array(WEEKS).fill(0),
        actual: new Array(WEEKS).fill(0),
      })
    })

    for (const r of staffWeekRows) {
      const sk = staffKey(r)
      if (!sk) continue
      const g = groups.get(sk.id)
      if (!g) continue
      const wIdx = weekIndex.get(String(r.pay_week_start ?? '').trim())
      if (wIdx == null) continue
      g.sales[wIdx] += parseNumOr0(r.total_sales_ex_gst)
      g.potential[wIdx] += parseNumOr0(r.total_theoretical_commission_ex_gst)
      g.actual[wIdx] += parseNumOr0(r.total_actual_commission_ex_gst)
    }

    return [...groups.values()]
  }, [selectedStaffIds, staffOptions, staffWeekRows, weekStarts])

  /* Convert SeriesGroup -> chart series for each metric. Zero-filling
   * means there are no nulls; the line traces 0 across weeks with no
   * activity so the graph has no gaps (matches the brief). */
  const salesSeries: StaffTrendsSeries[] = useMemo(
    () =>
      seriesGroups.map((g) => ({
        staffId: g.staffId,
        staffName: g.staffName,
        color: g.color,
        values: g.sales,
      })),
    [seriesGroups],
  )
  const potentialSeries: StaffTrendsSeries[] = useMemo(
    () =>
      seriesGroups.map((g) => ({
        staffId: g.staffId,
        staffName: g.staffName,
        color: g.color,
        values: g.potential,
      })),
    [seriesGroups],
  )
  const actualSeries: StaffTrendsSeries[] = useMemo(
    () =>
      seriesGroups.map((g) => ({
        staffId: g.staffId,
        staffName: g.staffName,
        color: g.color,
        values: g.actual,
      })),
    [seriesGroups],
  )

  /* Table rows: one per (week, staff). Sort newest week first, then
   * staff name; only weeks with any activity to keep the table compact. */
  const tableRows = useMemo<TableRow[]>(() => {
    const out: TableRow[] = []
    for (const g of seriesGroups) {
      for (let i = 0; i < WEEKS; i++) {
        const sales = g.sales[i]
        const potential = g.potential[i]
        const actual = g.actual[i]
        if (sales === 0 && potential === 0 && actual === 0) continue
        out.push({
          payWeekStart: weekStarts[i],
          staffId: g.staffId,
          staffName: g.staffName,
          sales,
          potential,
          actual,
        })
      }
    }
    out.sort((a, b) => {
      if (a.payWeekStart !== b.payWeekStart) {
        return b.payWeekStart.localeCompare(a.payWeekStart)
      }
      return a.staffName.localeCompare(b.staffName, undefined, {
        sensitivity: 'base',
      })
    })
    return out
  }, [seriesGroups, weekStarts])

  /* ---------------- render ---------------- */

  if (isLoading) {
    return (
      <div data-testid="staff-trends-page">
        <LoadingState message="Loading staff trends..." testId="staff-trends-loading" />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="staff-trends-page">
        <ErrorState
          title="Could not load staff trends"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="staff-trends-error"
        />
      </div>
    )
  }

  const noStaffSelected = selectedStaffIds.length === 0

  return (
    <div data-testid="staff-trends-page" className="flex flex-col gap-4">
      <PageHeader
        title="Staff trends"
        description={`Weekly sales and commission for selected staff over the last ${WEEKS} pay weeks. Pay weeks run Monday to Sunday and reuse the Sales summary numbers.`}
      />

      {/* Filters card */}
      <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
        <div className="grid gap-4 sm:grid-cols-12">
          <div className="sm:col-span-7">
            <StaffTrendsStaffPicker
              options={staffOptions}
              selectedIds={selectedStaffIds}
              onChange={setSelectedStaffIds}
            />
          </div>
          <div className="sm:col-span-5">
            <div className="flex flex-col gap-2">
              <label
                htmlFor="staff-trends-location"
                className="text-sm font-medium text-slate-700"
              >
                Location
              </label>
              <select
                id="staff-trends-location"
                className="w-full rounded-md border border-slate-200 px-3 py-1.5 text-sm focus:border-violet-300 focus:outline-none focus:ring-2 focus:ring-violet-200"
                value={locationId}
                onChange={(e) => setLocationId(e.target.value)}
              >
                <option value="">All locations</option>
                {locationOptions.map((o) => (
                  <option key={o.id} value={o.id}>
                    {o.label}
                  </option>
                ))}
              </select>

              <label className="mt-2 text-sm font-medium text-slate-700">
                Date range
              </label>
              <p className="text-sm text-slate-600">
                Last {WEEKS} pay weeks
                <span className="ml-2 text-slate-400">
                  ({formatWeekLong(weekStarts[0])} to {formatWeekLong(weekStarts[WEEKS - 1])})
                </span>
              </p>
            </div>
          </div>
        </div>
      </section>

      {noStaffSelected ? (
        <section className="rounded-xl border border-dashed border-slate-200 bg-white px-6 py-12 text-center">
          <p className="text-sm font-medium text-slate-800">
            Select one or more staff members to view weekly sales and
            commission trends.
          </p>
          <p className="mt-1 text-sm text-slate-600">
            Numbers match the Sales summary page filtered to the same staff
            and date range.
          </p>
        </section>
      ) : (
        <>
          <ChartCard
            title="Sales (ex GST)"
            subtitle="Weekly sales excluding GST and vouchers."
            weekStarts={weekStarts}
            series={salesSeries}
          />
          <ChartCard
            title="Potential commission (ex GST)"
            subtitle="What commission would be if every line paid out at the plan's rate."
            weekStarts={weekStarts}
            series={potentialSeries}
          />
          <ChartCard
            title="Actual commission (ex GST)"
            subtitle="Commission actually accrued after thresholds and exclusions."
            weekStarts={weekStarts}
            series={actualSeries}
          />

          <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
            <div className="mb-3 flex items-center justify-between">
              <h2 className="text-base font-semibold text-slate-800">
                Weekly breakdown
              </h2>
              <span className="text-xs text-slate-500">
                {tableRows.length} {tableRows.length === 1 ? 'row' : 'rows'}
              </span>
            </div>
            {tableRows.length === 0 ? (
              <p className="text-sm text-slate-600">
                No sales for the selected staff in the last {WEEKS} weeks.
              </p>
            ) : (
              <div className="overflow-x-auto">
                <table className="min-w-full divide-y divide-slate-200 text-sm">
                  <thead className="bg-slate-50 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">
                    <tr>
                      <th scope="col" className="px-3 py-2">Week beginning</th>
                      <th scope="col" className="px-3 py-2">Staff member</th>
                      <th scope="col" className="px-3 py-2 text-right">Sales (ex GST)</th>
                      <th scope="col" className="px-3 py-2 text-right">Potential commission (ex GST)</th>
                      <th scope="col" className="px-3 py-2 text-right">Actual commission (ex GST)</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-slate-100">
                    {tableRows.map((r) => (
                      <tr key={`${r.payWeekStart}-${r.staffId}`}>
                        <td className="px-3 py-1.5 text-slate-700">
                          {formatWeekLong(r.payWeekStart)}
                        </td>
                        <td className="px-3 py-1.5 text-slate-700">{r.staffName}</td>
                        <td className="px-3 py-1.5 text-right tabular-nums text-slate-800">
                          {formatNzd(r.sales)}
                        </td>
                        <td className="px-3 py-1.5 text-right tabular-nums text-slate-800">
                          {formatNzd(r.potential)}
                        </td>
                        <td className="px-3 py-1.5 text-right tabular-nums text-slate-800">
                          {formatNzd(r.actual)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </section>
        </>
      )}
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Inline card around each line chart                                   */
/* ------------------------------------------------------------------ */

function ChartCard({
  title,
  subtitle,
  weekStarts,
  series,
}: {
  title: string
  subtitle: string
  weekStarts: string[]
  series: StaffTrendsSeries[]
}) {
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <div className="mb-1 flex items-baseline justify-between gap-3">
        <h2 className="text-base font-semibold text-slate-800">{title}</h2>
      </div>
      <p className="mb-3 text-sm text-slate-600">{subtitle}</p>

      <StaffTrendsLineChart weekStarts={weekStarts} series={series} />

      {/* Legend */}
      <ul className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-700">
        {series.map((s) => (
          <li key={s.staffId} className="flex items-center gap-1.5">
            <span
              aria-hidden
              className="inline-block h-2.5 w-2.5 rounded-full"
              style={{ background: s.color }}
            />
            <span>{s.staffName}</span>
          </li>
        ))}
      </ul>
    </section>
  )
}
