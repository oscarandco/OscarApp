import { useMemo, useState } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import {
  StaffTrendsLineChart,
  type StaffTrendsSeries,
} from '@/features/admin/components/StaffTrendsLineChart'
import { useAdminPayrollSummaryWeekly } from '@/features/admin/hooks/useAdminPayrollSummaryWeekly'
import { useStaffConfiguration } from '@/features/admin/hooks/useStaffConfiguration'
import type { StaffMemberRow } from '@/features/admin/types/staffConfiguration'
import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { aggregateWeeklyCommissionSummaryByStaffWeek } from '@/lib/aggregateWeeklyCommissionSummaryByStaffWeek'
import { formatNzd } from '@/lib/formatters'
import { uniqueLocationOptions } from '@/lib/payrollSummaryFilters'
import { queryErrorDetail } from '@/lib/queryError'

/* ------------------------------------------------------------------ */
/* Constants                                                            */
/* ------------------------------------------------------------------ */

const WEEKS = 52
const MAX_SELECTED = 12

/** Fixed colours for the three metric lines on every per-staff chart. */
const METRIC_COLORS = {
  sales: '#0ea5e9', // sky-500
  potential: '#f59e0b', // amber-500
  actual: '#7c3aed', // violet-600
}
const METRIC_LABELS = {
  sales: 'Sales ex GST',
  potential: 'Potential commission ex GST',
  actual: 'Actual commission ex GST',
}

/* ------------------------------------------------------------------ */
/* Date helpers (Monday-Sunday pay weeks, UTC to avoid TZ shifts).     */
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

/** Mirrors StaffConfigurationPage's StaffNavRow: show full_name in parens
 * when it differs from the display label, so duplicate display names can
 * be told apart. */
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

const BUCKET_LABEL: Record<StaffBucket, string> = {
  stylists: 'Stylists',
  assistants: 'Assistants',
  admin: 'Admin',
  other: 'Other',
}
const BUCKET_ORDER: StaffBucket[] = ['stylists', 'assistants', 'admin', 'other']

export function StaffTrendsPage() {
  const trends = useAdminPayrollSummaryWeekly()
  const staffCfg = useStaffConfiguration()

  const [selectedStaffIds, setSelectedStaffIds] = useState<string[]>([])
  const [locationId, setLocationId] = useState('')
  const [search, setSearch] = useState('')

  /* 52-week window anchored on "today's Monday" (UTC). */
  const mostRecentMonday = useMemo(() => payWeekStartFor(new Date()), [])
  const weekStarts = useMemo(
    () => buildWeekStartList(mostRecentMonday, WEEKS),
    [mostRecentMonday],
  )
  const weekStartSet = useMemo(() => new Set(weekStarts), [weekStarts])

  const trendRows = trends.data ?? []
  const staffMembers: StaffMemberRow[] = staffCfg.data?.staff ?? []

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
   * same attribution as Sales summary's split-rows view. */
  const staffWeekRows = useMemo(
    () => aggregateWeeklyCommissionSummaryByStaffWeek(scopedRows),
    [scopedRows],
  )

  /* Location options come from the same trend rows so only locations
   * with payroll data appear (matches Sales summary). */
  const locationOptions = useMemo(
    () => uniqueLocationOptions(trendRows),
    [trendRows],
  )

  /* ---------------- left nav: filtered + grouped ---------------- */

  const filteredStaff = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (q === '') return staffMembers
    return staffMembers.filter((s) => {
      const hay =
        `${s.full_name ?? ''} ${s.display_name ?? ''} ${s.primary_role ?? ''}`.toLowerCase()
      return hay.includes(q)
    })
  }, [staffMembers, search])

  const groupedStaff = useMemo(() => {
    const buckets: Record<StaffBucket, StaffMemberRow[]> = {
      stylists: [],
      assistants: [],
      admin: [],
      other: [],
    }
    for (const s of filteredStaff) {
      buckets[staffNavBucket(s)].push(s)
    }
    for (const b of BUCKET_ORDER) buckets[b].sort(compareStaff)
    return buckets
  }, [filteredStaff])

  /* Selected name lookup (preserves selection even if the user later
   * filters the row out of the visible list). */
  const staffNameById = useMemo(() => {
    const map = new Map<string, string>()
    for (const s of staffMembers) map.set(s.id, staffPrimaryLabel(s))
    return map
  }, [staffMembers])

  /* Build one SeriesGroup per selected staff member, zero-filled across
   * the 52-week window so each per-staff chart draws a continuous line. */
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

  /* Table: only weeks with non-zero activity, newest first. */
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
      className="flex min-h-0 w-full flex-col lg:h-[calc(100dvh-7.5rem)] lg:min-h-0 lg:overflow-hidden"
    >
      <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-hidden pb-4 pl-2 pr-4 pt-2 sm:pl-3 sm:pr-6 lg:flex-row lg:pt-3">
        {/* ---------- Left pane: staff list ---------- */}
        <aside
          className="flex min-h-0 w-full shrink-0 flex-col border-b border-slate-200 bg-white px-3 py-3 shadow-sm max-h-[min(46vh,26rem)] sm:px-4 lg:max-h-none lg:h-full lg:w-72 lg:overflow-hidden lg:rounded-lg lg:border lg:border-slate-200 lg:py-4 lg:shadow-sm"
          data-testid="staff-trends-left-pane"
        >
          <div className="flex items-center justify-between gap-2">
            <h2 className="text-sm font-semibold text-slate-800">Staff</h2>
            <span
              className="text-xs text-slate-500"
              data-testid="staff-trends-selected-count"
            >
              {selectedStaffIds.length} selected
            </span>
          </div>

          <div className="mt-2">
            <label htmlFor="staff-trends-search" className="sr-only">
              Search staff
            </label>
            <input
              id="staff-trends-search"
              type="search"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
              placeholder="Search staff..."
              autoComplete="off"
              className="w-full rounded-md border border-slate-300 px-3 py-1.5 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
            />
          </div>

          {selectedStaffIds.length > 0 ? (
            <div className="mt-2 flex items-center justify-end gap-3 text-xs">
              {atLimit ? (
                <span className="text-slate-500">Max {MAX_SELECTED} reached</span>
              ) : null}
              <button
                type="button"
                onClick={clearSelection}
                className="text-slate-500 hover:text-slate-800 hover:underline"
              >
                Clear
              </button>
            </div>
          ) : null}

          <div
            className="mt-3 min-h-0 flex-1 overflow-y-auto pr-0.5"
            data-testid="staff-trends-staff-list"
          >
            {filteredStaff.length === 0 ? (
              <p className="text-sm text-slate-500">
                No staff match your search.
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
                          return (
                            <StaffTrendsNavRow
                              key={s.id}
                              member={s}
                              active={active}
                              disabled={disabled}
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

        {/* ---------- Right pane: header + filters + charts + table ---------- */}
        <div className="min-h-0 min-w-0 flex-1 overflow-y-auto pb-6 pt-0">
          <PageHeader
            title="Staff trends"
            description="Weekly sales and commission trends for selected staff."
          />

          {/* Top controls: location + date range */}
          <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
            <div className="grid items-end gap-4 sm:grid-cols-12">
              <div className="sm:col-span-5">
                <label
                  htmlFor="staff-trends-location"
                  className="block text-xs font-medium text-slate-600"
                >
                  Location
                </label>
                <select
                  id="staff-trends-location"
                  className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
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
              </div>
              <div className="sm:col-span-5">
                <span className="block text-xs font-medium text-slate-600">
                  Date range
                </span>
                <p className="mt-1.5 text-sm text-slate-700">
                  Last {WEEKS} pay weeks
                  <span className="ml-2 text-slate-400">
                    ({formatWeekLong(weekStarts[0])} to {formatWeekLong(weekStarts[WEEKS - 1])})
                  </span>
                </p>
              </div>
              <div className="sm:col-span-2 sm:text-right">
                {selectedStaffIds.length > 0 ? (
                  <button
                    type="button"
                    onClick={clearSelection}
                    className="inline-flex w-full items-center justify-center rounded-md border border-slate-300 px-3 py-1.5 text-sm text-slate-700 hover:bg-slate-50 sm:w-auto"
                  >
                    Clear selection
                  </button>
                ) : null}
              </div>
            </div>
          </section>

          {noStaffSelected ? (
            <section className="mt-4 rounded-xl border border-dashed border-slate-200 bg-white px-6 py-12 text-center">
              <p className="text-sm font-medium text-slate-800">
                Select one or more staff members to view weekly sales and
                commission trends.
              </p>
              <p className="mt-1 text-sm text-slate-600">
                Numbers match the Sales summary page filtered to the same
                staff and date range.
              </p>
            </section>
          ) : (
            <div className="mt-4 flex flex-col gap-4">
              {seriesGroups.map((g) => (
                <StaffChartCard key={g.staffId} group={g} weekStarts={weekStarts} />
              ))}

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
            </div>
          )}
        </div>
      </div>
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Left-pane row (click-to-toggle, multi-select)                       */
/* Visual style mirrors StaffConfigurationPage's StaffNavRow.           */
/* ------------------------------------------------------------------ */

function StaffTrendsNavRow({
  member,
  active,
  disabled,
  onToggle,
}: {
  member: StaffMemberRow
  active: boolean
  disabled: boolean
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
          <span className="min-w-0 flex-1 truncate">
            <span
              className={`font-medium ${active ? 'text-violet-950' : 'text-slate-900'}`}
            >
              {primary}
            </span>
            {sub ? (
              <span className="text-xs font-normal text-slate-500"> ({sub})</span>
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
/* Chart card (one per staff member, with 3 metric lines)              */
/* ------------------------------------------------------------------ */

function StaffChartCard({
  group,
  weekStarts,
}: {
  group: SeriesGroup
  weekStarts: string[]
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
      <h2 className="mb-1 text-base font-semibold text-slate-800">
        {group.staffName}
      </h2>
      <p className="mb-3 text-sm text-slate-600">
        Sales, potential commission and actual commission over the last {WEEKS} pay weeks.
      </p>

      <StaffTrendsLineChart weekStarts={weekStarts} series={series} />

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
