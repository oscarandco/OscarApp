import { useMemo, useState } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { StaffLocationNavBadge } from '@/features/admin/components/StaffLocationNavBadge'
import {
  StaffTrendsLineChart,
  type StaffTrendsSeries,
} from '@/features/admin/components/StaffTrendsLineChart'
import {
  StaffTrendsStackedSalesChart,
  type StackedSalesWeek,
} from '@/features/admin/components/StaffTrendsStackedSalesChart'
import { useAdminPayrollSummaryWeekly } from '@/features/admin/hooks/useAdminPayrollSummaryWeekly'
import { useStaffConfiguration } from '@/features/admin/hooks/useStaffConfiguration'
import type { StaffMemberRow } from '@/features/admin/types/staffConfiguration'
import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { aggregateWeeklyCommissionSummaryByStaffWeek } from '@/lib/aggregateWeeklyCommissionSummaryByStaffWeek'
import { formatNzd } from '@/lib/formatters'
import { primaryLocationNavBadge } from '@/lib/locationNavBadge'
import { queryErrorDetail } from '@/lib/queryError'
import type { ImportLocationRow } from '@/lib/supabaseRpc'

/* ------------------------------------------------------------------ */
/* Constants                                                            */
/* ------------------------------------------------------------------ */

const WEEKS = 52
const MAX_SELECTED = 12

const METRIC_COLORS = {
  sales: '#0ea5e9',
  potential: '#f59e0b',
  actual: '#7c3aed',
}
const METRIC_LABELS = {
  sales: 'Sales ex GST',
  potential: 'Potential commission ex GST',
  actual: 'Actual commission ex GST',
}

/** Stable palette used by the stacked overview. */
const STACK_PALETTE = [
  '#7c3aed', '#0ea5e9', '#16a34a', '#f59e0b', '#ef4444',
  '#0891b2', '#db2777', '#65a30d', '#9333ea', '#0d9488',
  '#ea580c', '#475569', '#a855f7', '#06b6d4', '#84cc16',
  '#fb923c',
]

/** Deterministic colour for a staff id (stable across renders/sessions). */
function colorForStaffId(id: string): string {
  let h = 0
  for (let i = 0; i < id.length; i++) {
    h = ((h << 5) - h + id.charCodeAt(i)) | 0
  }
  return STACK_PALETTE[Math.abs(h) % STACK_PALETTE.length]
}

/* ------------------------------------------------------------------ */
/* Date helpers (Monday-Sunday pay weeks, UTC)                          */
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

function payWeekStartFor(d: Date): Date {
  const isoDow = ((d.getUTCDay() + 6) % 7) + 1
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

function staffPrimaryLabel(s: StaffMemberRow): string {
  const disp = (s.display_name ?? '').trim()
  return disp !== '' ? disp : s.full_name.trim()
}

function staffSubLabel(s: StaffMemberRow): string | null {
  const disp = (s.display_name ?? '').trim()
  const full = s.full_name.trim()
  if (disp === '') return null
  if (disp.toLowerCase() === full.toLowerCase()) return null
  return full
}

type StaffBucket = 'stylists' | 'assistants' | 'admin' | 'other'

function staffNavBucket(row: StaffMemberRow): StaffBucket {
  const role = (row.primary_role ?? '').trim().toLowerCase()
  if (
    role.includes('stylist') ||
    role.includes('colourist') ||
    role.includes('colorist')
  ) {
    return 'stylists'
  }
  if (role.includes('assistant')) return 'assistants'
  if (
    role.includes('admin') ||
    role.includes('manager') ||
    role.includes('owner') ||
    role.includes('director')
  ) {
    return 'admin'
  }
  return 'other'
}

function compareStaff(a: StaffMemberRow, b: StaffMemberRow): number {
  if (a.is_active !== b.is_active) return a.is_active ? -1 : 1
  const an = staffPrimaryLabel(a).toLowerCase()
  const bn = staffPrimaryLabel(b).toLowerCase()
  return an.localeCompare(bn, undefined, { sensitivity: 'base' })
}

const BUCKET_LABEL: Record<StaffBucket, string> = {
  stylists: 'Stylists',
  assistants: 'Assistants',
  admin: 'Admin',
  other: 'Other',
}
const BUCKET_ORDER: StaffBucket[] = ['stylists', 'assistants', 'admin', 'other']

type StatusFilter = 'active' | 'inactive' | 'all'

/* ------------------------------------------------------------------ */
/* Page                                                                 */
/* ------------------------------------------------------------------ */

type SeriesGroup = {
  staffId: string
  staffName: string
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
  const trends = useAdminPayrollSummaryWeekly()
  const staffCfg = useStaffConfiguration()

  const [selectedStaffIds, setSelectedStaffIds] = useState<string[]>([])
  const [locationId, setLocationId] = useState('')
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('active')
  const [showAllSales, setShowAllSales] = useState(true)

  /* 52-week window anchored on "today's Monday" (UTC). */
  const mostRecentMonday = useMemo(() => payWeekStartFor(new Date()), [])
  const weekStarts = useMemo(
    () => buildWeekStartList(mostRecentMonday, WEEKS),
    [mostRecentMonday],
  )
  const weekStartSet = useMemo(() => new Set(weekStarts), [weekStarts])

  const trendRows = trends.data ?? []
  const staffMembers: StaffMemberRow[] = staffCfg.data?.staff ?? []
  const locations: ImportLocationRow[] = staffCfg.data?.locations ?? []

  /* Scoped trend rows for charting (52-week window + optional location). */
  const scopedRows = useMemo(() => {
    const out: WeeklyCommissionSummaryRow[] = []
    for (const r of trendRows) {
      const w = String(r.pay_week_start ?? '').trim()
      if (!weekStartSet.has(w)) continue
      if (locationId !== '' && String(r.location_id ?? '') !== locationId) continue
      out.push(r)
    }
    return out
  }, [trendRows, weekStartSet, locationId])

  /* One row per (week, staff), summed across locations. Same helper +
   * same attribution as Sales summary. */
  const staffWeekRows = useMemo(
    () => aggregateWeeklyCommissionSummaryByStaffWeek(scopedRows),
    [scopedRows],
  )

  /* ---------------- left nav: status + location filters ---------------- */

  const visibleStaff = useMemo(() => {
    return staffMembers.filter((s) => {
      if (statusFilter === 'active' && !s.is_active) return false
      if (statusFilter === 'inactive' && s.is_active) return false
      if (
        locationId !== '' &&
        String(s.primary_location_id ?? '') !== locationId
      ) {
        return false
      }
      return true
    })
  }, [staffMembers, statusFilter, locationId])

  const groupedStaff = useMemo(() => {
    const buckets: Record<StaffBucket, StaffMemberRow[]> = {
      stylists: [],
      assistants: [],
      admin: [],
      other: [],
    }
    for (const s of visibleStaff) buckets[staffNavBucket(s)].push(s)
    for (const b of BUCKET_ORDER) buckets[b].sort(compareStaff)
    return buckets
  }, [visibleStaff])

  /* Display name lookup across ALL staff (so selected staff that get
   * filtered out of the list keep correct names on their chart). */
  const staffNameById = useMemo(() => {
    const map = new Map<string, string>()
    for (const s of staffMembers) map.set(s.id, staffPrimaryLabel(s))
    return map
  }, [staffMembers])

  /* ---------------- selected-staff line series ---------------- */

  const seriesGroups = useMemo<SeriesGroup[]>(() => {
    if (selectedStaffIds.length === 0) return []
    const weekIndex = new Map<string, number>()
    weekStarts.forEach((w, i) => weekIndex.set(w, i))

    const groups: SeriesGroup[] = selectedStaffIds.map((id) => ({
      staffId: id,
      staffName: staffNameById.get(id) ?? '(Unknown)',
      sales: new Array(WEEKS).fill(0),
      potential: new Array(WEEKS).fill(0),
      actual: new Array(WEEKS).fill(0),
    }))
    const indexById = new Map<string, number>()
    groups.forEach((g, i) => indexById.set(g.staffId, i))

    for (const r of staffWeekRows) {
      const sid = String(r.derived_staff_paid_id ?? '').trim()
      if (sid === '') continue
      const gi = indexById.get(sid)
      if (gi == null) continue
      const wIdx = weekIndex.get(String(r.pay_week_start ?? '').trim())
      if (wIdx == null) continue
      const g = groups[gi]
      g.sales[wIdx] += parseNumOr0(r.total_sales_ex_gst)
      g.potential[wIdx] += parseNumOr0(r.total_theoretical_commission_ex_gst)
      g.actual[wIdx] += parseNumOr0(r.total_actual_commission_ex_gst)
    }

    return groups
  }, [selectedStaffIds, staffNameById, staffWeekRows, weekStarts])

  /* ---------------- all-staff stacked weekly sales ---------------- */

  const stackedWeeks = useMemo<StackedSalesWeek[]>(() => {
    if (!showAllSales) return []
    const weekIndex = new Map<string, number>()
    weekStarts.forEach((w, i) => weekIndex.set(w, i))

    type Acc = { value: number; name: string }
    const buckets: Map<string, Acc>[] = weekStarts.map(() => new Map())
    const totals = new Map<string, number>()

    for (const r of staffWeekRows) {
      const sid = String(r.derived_staff_paid_id ?? '').trim()
      if (sid === '') continue
      const wIdx = weekIndex.get(String(r.pay_week_start ?? '').trim())
      if (wIdx == null) continue
      const v = parseNumOr0(r.total_sales_ex_gst)
      if (v <= 0) continue
      const fromStaff = staffNameById.get(sid)
      const fromRow = String(r.derived_staff_paid_display_name ?? '').trim()
      const name = fromStaff ?? (fromRow !== '' ? fromRow : '(Unknown)')
      const cur = buckets[wIdx].get(sid) ?? { value: 0, name }
      cur.value += v
      cur.name = name
      buckets[wIdx].set(sid, cur)
      totals.set(sid, (totals.get(sid) ?? 0) + v)
    }

    /* Stable per-bar segment order: by total contribution descending, so
     * the biggest contributor sits at the bottom of every bar. */
    const stackOrder = [...totals.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([id]) => id)

    return weekStarts.map((weekStart, i) => {
      const w = buckets[i]
      let total = 0
      const segments = stackOrder
        .map((sid) => {
          const acc = w.get(sid)
          if (!acc) return null
          total += acc.value
          return {
            staffId: sid,
            staffName: acc.name,
            color: colorForStaffId(sid),
            value: acc.value,
          }
        })
        .filter((s): s is NonNullable<typeof s> => s !== null)
      return { weekStart, total, segments }
    })
  }, [showAllSales, staffWeekRows, staffNameById, weekStarts])

  /* ---------------- shared Y-axis across selected staff charts ---- */

  /* Pick the max Sales ex GST across all selected staff and all weeks
   * so every per-staff line chart shares the same vertical scale,
   * making Leah vs Jarod comparable at a glance. Sales is always the
   * largest of the three metrics on a given week, so this also covers
   * Potential and Actual commission.
   *
   * Round up to the nearest $1,000 (e.g. $2,965 -> $3,000, $4,001 ->
   * $5,000, $3,000 -> $3,000) so the axis tick labels are tidy without
   * being misleadingly large. */
  const sharedYMax = useMemo(() => {
    let m = 0
    for (const g of seriesGroups) {
      for (const v of g.sales) {
        if (v > m) m = v
      }
    }
    if (m <= 0) return 0
    return Math.ceil(m / 1000) * 1000
  }, [seriesGroups])

  /* ---------------- table rows ---------------- */

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

  /* ---------------- handlers ---------------- */

  function toggleStaff(id: string) {
    setSelectedStaffIds((cur) => {
      if (cur.includes(id)) return cur.filter((x) => x !== id)
      if (cur.length >= MAX_SELECTED) return cur
      return [...cur, id]
    })
  }

  function clearSelection() {
    setSelectedStaffIds([])
  }

  /* ---------------- render guards ---------------- */

  const isLoading = trends.isLoading || staffCfg.isLoading

  if (isLoading) {
    return (
      <div data-testid="staff-trends-page">
        <LoadingState
          message="Loading staff trends..."
          testId="staff-trends-loading"
        />
      </div>
    )
  }

  if (trends.isError) {
    const { message, err } = queryErrorDetail(trends.error)
    return (
      <div data-testid="staff-trends-page">
        <ErrorState
          title="Could not load staff trends"
          error={err}
          message={message}
          onRetry={() => void trends.refetch()}
          testId="staff-trends-error"
        />
      </div>
    )
  }

  if (staffCfg.isError) {
    const { message, err } = queryErrorDetail(staffCfg.error)
    return (
      <div data-testid="staff-trends-page">
        <ErrorState
          title="Could not load staff list"
          error={err}
          message={message}
          onRetry={() => void staffCfg.refetch()}
          testId="staff-trends-staff-error"
        />
      </div>
    )
  }

  const noStaffSelected = selectedStaffIds.length === 0
  const atLimit = selectedStaffIds.length >= MAX_SELECTED

  return (
    <div
      data-testid="staff-trends-page"
      className="flex w-full flex-col gap-4 pb-6 pl-2 pr-4 pt-2 sm:pl-3 sm:pr-6 lg:flex-row lg:items-start"
    >
        {/* ---------- Left pane ---------- */}
        <aside
          className="w-full shrink-0 rounded-lg border border-slate-200 bg-white px-3 py-3 shadow-sm sm:px-4 lg:sticky lg:top-3 lg:flex lg:max-h-[calc(100dvh-5rem)] lg:w-72 lg:flex-col lg:py-4"
          data-testid="staff-trends-left-pane"
        >
          {/* Header: title + counter + clear */}
          <div className="flex items-center justify-between gap-2">
            <h2 className="text-sm font-semibold text-slate-800">
              Staff trends
            </h2>
            <span
              className="text-xs text-slate-500"
              data-testid="staff-trends-selected-count"
            >
              {selectedStaffIds.length} selected
              {selectedStaffIds.length > 0 ? (
                <button
                  type="button"
                  onClick={clearSelection}
                  className="ml-2 text-slate-500 hover:text-slate-800 hover:underline"
                >
                  Clear
                </button>
              ) : null}
            </span>
          </div>

          {/* Show / Hide all sales graph */}
          <button
            type="button"
            onClick={() => setShowAllSales((v) => !v)}
            className="mt-3 w-full rounded-md border border-slate-300 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 shadow-sm hover:bg-slate-50"
            aria-pressed={showAllSales}
            data-testid="staff-trends-toggle-all-sales"
          >
            {showAllSales ? 'Hide all sales graph' : 'Show all sales graph'}
          </button>

          {/* Compact horizontal filters */}
          <div className="mt-3 space-y-2">
            <div className="flex items-center gap-2">
              <label
                htmlFor="staff-trends-location"
                className="w-16 shrink-0 text-xs font-medium text-slate-600"
              >
                Location
              </label>
              <select
                id="staff-trends-location"
                className="min-w-0 flex-1 rounded-md border border-slate-300 px-2 py-1.5 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                value={locationId}
                onChange={(e) => setLocationId(e.target.value)}
              >
                <option value="">All locations</option>
                {locations.map((l) => (
                  <option key={l.id} value={l.id}>
                    {l.name}
                  </option>
                ))}
              </select>
            </div>
            <div className="flex items-center gap-2">
              <label
                htmlFor="staff-trends-status"
                className="w-16 shrink-0 text-xs font-medium text-slate-600"
              >
                Status
              </label>
              <select
                id="staff-trends-status"
                className="min-w-0 flex-1 rounded-md border border-slate-300 px-2 py-1.5 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                value={statusFilter}
                onChange={(e) =>
                  setStatusFilter(e.target.value as StatusFilter)
                }
              >
                <option value="active">Active</option>
                <option value="inactive">Inactive</option>
                <option value="all">All</option>
              </select>
            </div>
          </div>

          {/* Staff list */}
          <div
            className="mt-3 min-h-0 max-h-[60vh] flex-1 overflow-y-auto pr-0.5 lg:max-h-none"
            data-testid="staff-trends-staff-list"
          >
            {visibleStaff.length === 0 ? (
              <p className="text-sm text-slate-500">
                No staff match these filters.
              </p>
            ) : (
              <div className="space-y-4 pb-2">
                {BUCKET_ORDER.map((bucket) => {
                  const rows = groupedStaff[bucket]
                  if (rows.length === 0) return null
                  return (
                    <div key={bucket}>
                      <h3 className="sticky top-0 z-10 bg-white pb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
                        {BUCKET_LABEL[bucket]}
                      </h3>
                      <ul className="mt-1 space-y-1">
                        {rows.map((s) => {
                          const active = selectedStaffIds.includes(s.id)
                          const disabled = !active && atLimit
                          const locBadge = primaryLocationNavBadge(
                            s.primary_location_id,
                            locations,
                          )
                          return (
                            <StaffTrendsNavRow
                              key={s.id}
                              member={s}
                              active={active}
                              disabled={disabled}
                              locationBadge={locBadge}
                              onToggle={toggleStaff}
                            />
                          )
                        })}
                      </ul>
                    </div>
                  )
                })}
              </div>
            )}
          </div>
        </aside>

        {/* ---------- Right pane (scrolls with the page) ---------- */}
        <div className="flex min-w-0 flex-1 flex-col gap-4">
            {showAllSales ? (
              <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
                <h2 className="mb-3 text-base font-semibold text-slate-800">
                  All staff sales by week
                </h2>
                <StaffTrendsStackedSalesChart weeks={stackedWeeks} />
              </section>
            ) : null}

            {noStaffSelected ? (
              <section className="rounded-xl border border-dashed border-slate-200 bg-white px-6 py-12 text-center">
                <p className="text-sm font-medium text-slate-800">
                  Select a staff member to see their sales and commission
                  trend.
                </p>
                <p className="mt-1 text-sm text-slate-600">
                  Numbers match the Sales summary page filtered to the same
                  staff and date range.
                </p>
              </section>
            ) : (
              <>
                {seriesGroups.map((g) => (
                  <StaffChartCard
                    key={g.staffId}
                    group={g}
                    weekStarts={weekStarts}
                    yMax={sharedYMax}
                  />
                ))}

                <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
                  <div className="mb-3 flex items-center justify-between">
                    <h2 className="text-base font-semibold text-slate-800">
                      Weekly breakdown
                    </h2>
                    <span className="text-xs text-slate-500">
                      {tableRows.length}{' '}
                      {tableRows.length === 1 ? 'row' : 'rows'}
                    </span>
                  </div>
                  {tableRows.length === 0 ? (
                    <p className="text-sm text-slate-600">
                      No sales for the selected staff in the last {WEEKS}{' '}
                      weeks.
                    </p>
                  ) : (
                    <div className="overflow-x-auto">
                      <table className="min-w-full divide-y divide-slate-200 text-sm">
                        <thead className="bg-slate-50 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">
                          <tr>
                            <th scope="col" className="px-3 py-2">
                              Week beginning
                            </th>
                            <th scope="col" className="px-3 py-2">
                              Staff member
                            </th>
                            <th
                              scope="col"
                              className="px-3 py-2 text-right"
                            >
                              Sales ex GST
                            </th>
                            <th
                              scope="col"
                              className="px-3 py-2 text-right"
                            >
                              Potential commission ex GST
                            </th>
                            <th
                              scope="col"
                              className="px-3 py-2 text-right"
                            >
                              Actual commission ex GST
                            </th>
                          </tr>
                        </thead>
                        <tbody className="divide-y divide-slate-100">
                          {tableRows.map((r) => (
                            <tr key={`${r.payWeekStart}-${r.staffId}`}>
                              <td className="px-3 py-1.5 text-slate-700">
                                {formatWeekLong(r.payWeekStart)}
                              </td>
                              <td className="px-3 py-1.5 text-slate-700">
                                {r.staffName}
                              </td>
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
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Left-pane row (click-to-toggle, multi-select)                       */
/* ------------------------------------------------------------------ */

function StaffTrendsNavRow({
  member,
  active,
  disabled,
  locationBadge,
  onToggle,
}: {
  member: StaffMemberRow
  active: boolean
  disabled: boolean
  locationBadge: 'O' | 'T' | null
  onToggle: (id: string) => void
}) {
  const primary = staffPrimaryLabel(member)
  const sub = staffSubLabel(member)
  return (
    <li>
      <button
        type="button"
        aria-pressed={active}
        disabled={disabled}
        onClick={() => onToggle(member.id)}
        className={`flex w-full items-center justify-between gap-2 rounded-lg border px-3 py-2.5 text-left text-sm transition ${
          active
            ? 'border-violet-300 bg-violet-50 text-violet-950'
            : disabled
              ? 'cursor-not-allowed border-transparent bg-slate-50/60 text-slate-400'
              : 'border-transparent bg-slate-50/80 text-slate-800 hover:border-slate-200 hover:bg-white'
        }`}
      >
        <span className="flex min-w-0 flex-1 items-center gap-1.5 text-left">
          <StaffLocationNavBadge letter={locationBadge} />
          <span className="min-w-0 flex-1 truncate">
            <span
              className={`font-medium ${active ? 'text-violet-950' : 'text-slate-900'}`}
            >
              {primary}
            </span>
            {sub ? (
              <span className="text-xs font-normal text-slate-500">
                {' '}
                ({sub})
              </span>
            ) : null}
          </span>
        </span>
        <span
          className={`shrink-0 text-xs font-medium ${
            member.is_active ? 'text-emerald-700' : 'text-slate-400'
          }`}
        >
          {member.is_active ? 'Active' : 'Inactive'}
        </span>
      </button>
    </li>
  )
}

/* ------------------------------------------------------------------ */
/* Per-staff line chart card                                            */
/* ------------------------------------------------------------------ */

function StaffChartCard({
  group,
  weekStarts,
  yMax,
}: {
  group: SeriesGroup
  weekStarts: string[]
  yMax: number
}) {
  const series: StaffTrendsSeries[] = [
    {
      id: 'sales',
      label: METRIC_LABELS.sales,
      color: METRIC_COLORS.sales,
      values: group.sales,
    },
    {
      id: 'potential',
      label: METRIC_LABELS.potential,
      color: METRIC_COLORS.potential,
      values: group.potential,
    },
    {
      id: 'actual',
      label: METRIC_LABELS.actual,
      color: METRIC_COLORS.actual,
      values: group.actual,
    },
  ]

  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <h2 className="mb-3 text-base font-semibold text-slate-800">
        {group.staffName}
      </h2>

      <StaffTrendsLineChart
        weekStarts={weekStarts}
        series={series}
        yMax={yMax}
        height={188}
      />

      <ul className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-700">
        {series.map((s) => (
          <li key={s.id} className="flex items-center gap-1.5">
            <span
              aria-hidden
              className="inline-block h-2.5 w-2.5 rounded-full"
              style={{ background: s.color }}
            />
            <span>{s.label}</span>
          </li>
        ))}
      </ul>
    </section>
  )
}
