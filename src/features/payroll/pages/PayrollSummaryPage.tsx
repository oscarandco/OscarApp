import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useAccessProfile } from '@/features/access/accessContext'
import {
  StaffTrendsLineChart,
  type StaffTrendsSeries,
} from '@/features/admin/components/StaffTrendsLineChart'
import { PayrollLinesPreviewModal } from '@/features/payroll/components/PayrollLinesPreviewModal'
import { useMySalesTrendWeekly } from '@/features/payroll/hooks/useMySalesTrendWeekly'
import type {
  AssistantCommissionContributor,
  MySalesTrendWeeklyRow,
  WeeklyCommissionSummaryRow,
} from '@/features/payroll/types'
import { formatNzd } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'
import { colorForStaffId } from '@/lib/staffColor'

/* ------------------------------------------------------------------ */
/* Constants                                                            */
/* ------------------------------------------------------------------ */

const WEEKS = 52

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

/* ------------------------------------------------------------------ */
/* Date helpers (Monday-Sunday pay weeks, UTC) - matched to Staff Trends */
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
/* Number / display helpers                                             */
/* ------------------------------------------------------------------ */

function parseNumOr0(v: unknown): number {
  if (v == null || v === '') return 0
  const n = typeof v === 'number' ? v : Number(v)
  return Number.isFinite(n) ? n : 0
}

/**
 * Same tiered "ceil-to-nice" rounding Staff Trends applies to each
 * per-staff chart when one staff member is selected. Keeps the My Sales
 * chart's Y axis at the same scale Staff Trends would draw for this
 * staff member alone:
 *   m <= 0    -> 100 (sensible fallback when nothing has sold)
 *   m < 1000  -> ceil to nearest $100
 *   m < 3000  -> ceil to nearest $500
 *   m >= 3000 -> ceil to nearest $1,000
 */
function ceilSharedYMax(m: number): number {
  if (m <= 0) return 100
  if (m < 1000) return Math.ceil(m / 100) * 100
  if (m < 3000) return Math.ceil(m / 500) * 500
  return Math.ceil(m / 1000) * 1000
}

/**
 * Potential commission and actual commission are the same calculation
 * for staff on a Commission or Contractor plan, so showing the
 * potential column for them is just noise. Wage staff (and any other
 * plan) keep the potential value because it represents what they would
 * have earned on commission - useful context for the conversation
 * "should I move to commission?".
 */
function isCommissionOrContractorPlan(plan: string | null | undefined): boolean {
  const p = (plan ?? '').trim().toLowerCase()
  if (p === '') return false
  return p.includes('commission') || p.includes('contractor')
}

function assistantInitial(name: string): string {
  const n = (name ?? '').trim()
  if (n === '') return '?'
  return n.charAt(0).toLowerCase()
}

function contributorKey(
  c: AssistantCommissionContributor,
  idx: number,
): string {
  const id = (c.staff_member_id ?? '').toString().trim()
  if (id !== '') return `id:${id}`
  return `n:${(c.display_name ?? '').toString().trim().toLowerCase()}:${idx}`
}

/**
 * Deterministic colour for an assistant contributor swatch. Prefer the
 * staff member id (matches Staff Trends colour for the same person);
 * fall back to a name-seeded id so contributors that were name-only
 * matched still get a stable colour.
 */
function contributorColor(c: AssistantCommissionContributor): string {
  const id = (c.staff_member_id ?? '').toString().trim()
  if (id !== '') return colorForStaffId(id)
  const name = (c.display_name ?? '').toString().trim().toLowerCase()
  return colorForStaffId(name === '' ? '' : `name:${name}`)
}

/* ------------------------------------------------------------------ */
/* Page                                                                 */
/* ------------------------------------------------------------------ */

export function PayrollSummaryPage() {
  const { normalized, accessState } = useAccessProfile()
  const myStaffId = (normalized?.staffMemberId ?? '').trim()

  const trend = useMySalesTrendWeekly()

  const [previewRow, setPreviewRow] =
    useState<WeeklyCommissionSummaryRow | null>(null)

  /* 52-week window anchored on today's Monday (UTC), same as Staff Trends. */
  const mostRecentMonday = useMemo(() => payWeekStartFor(new Date()), [])
  const weekStarts = useMemo(
    () => buildWeekStartList(mostRecentMonday, WEEKS),
    [mostRecentMonday],
  )
  const weekStartSet = useMemo(() => new Set(weekStarts), [weekStarts])

  /* RPC already returns at most one row per pay_week_start for the
   * caller's staff member (locations combined). Index by week for fast
   * chart-series construction. */
  const rowByWeek = useMemo(() => {
    const m = new Map<string, MySalesTrendWeeklyRow>()
    for (const r of trend.data ?? []) {
      const w = String(r.pay_week_start ?? '').trim()
      if (w === '') continue
      m.set(w, r)
    }
    return m
  }, [trend.data])

  /* Zero-filled per-week values across the 52-week window. */
  const rawSeries = useMemo(() => {
    const sales: number[] = new Array(WEEKS).fill(0)
    const potential: number[] = new Array(WEEKS).fill(0)
    const actual: number[] = new Array(WEEKS).fill(0)
    weekStarts.forEach((w, i) => {
      const r = rowByWeek.get(w)
      if (!r) return
      sales[i] = parseNumOr0(r.total_sales_ex_gst)
      potential[i] = parseNumOr0(r.total_theoretical_commission_ex_gst)
      actual[i] = parseNumOr0(r.total_actual_commission_ex_gst)
    })
    return { sales, potential, actual }
  }, [weekStarts, rowByWeek])

  /* Display-only: replace weeks where all three metrics are exactly 0
   * with null so the line renders as a gap instead of dropping to $0.
   * Same treatment Staff Trends individual cards use - catches the
   * Christmas shutdown weeks and the current incomplete week. */
  const { displaySales, displayPotential, displayActual } = useMemo(() => {
    const sales: (number | null)[] = new Array(WEEKS)
    const potential: (number | null)[] = new Array(WEEKS)
    const actual: (number | null)[] = new Array(WEEKS)
    for (let i = 0; i < WEEKS; i++) {
      const s = rawSeries.sales[i] ?? 0
      const p = rawSeries.potential[i] ?? 0
      const a = rawSeries.actual[i] ?? 0
      if (s === 0 && p === 0 && a === 0) {
        sales[i] = null
        potential[i] = null
        actual[i] = null
      } else {
        sales[i] = s
        potential[i] = p
        actual[i] = a
      }
    }
    return {
      displaySales: sales,
      displayPotential: potential,
      displayActual: actual,
    }
  }, [rawSeries.sales, rawSeries.potential, rawSeries.actual])

  /* Y axis scale = peak Sales ex GST across the window, then tier-ceiled.
   * Sales is always >= Potential and Actual on a given week, so this
   * also covers the commission lines. Same logic Staff Trends uses for
   * a single selected staff member (sharedYMax). */
  const yMax = useMemo(() => {
    let m = 0
    for (const v of rawSeries.sales) {
      if (v > m) m = v
    }
    return ceilSharedYMax(m)
  }, [rawSeries.sales])

  const chartSeries: StaffTrendsSeries[] = [
    {
      id: 'sales',
      label: METRIC_LABELS.sales,
      color: METRIC_COLORS.sales,
      values: displaySales,
    },
    {
      id: 'potential',
      label: METRIC_LABELS.potential,
      color: METRIC_COLORS.potential,
      values: displayPotential,
    },
    {
      id: 'actual',
      label: METRIC_LABELS.actual,
      color: METRIC_COLORS.actual,
      values: displayActual,
    },
  ]

  /* Weekly breakdown rows: every pay week within the 52-week window that
   * has any non-zero metric, newest first. Mirrors Staff Trends table. */
  const tableRows = useMemo(() => {
    const out: MySalesTrendWeeklyRow[] = []
    for (const r of trend.data ?? []) {
      const w = String(r.pay_week_start ?? '').trim()
      if (w === '' || !weekStartSet.has(w)) continue
      const sales = parseNumOr0(r.total_sales_ex_gst)
      const potential = parseNumOr0(r.total_theoretical_commission_ex_gst)
      const actual = parseNumOr0(r.total_actual_commission_ex_gst)
      const asst = parseNumOr0(r.total_assistant_commission_ex_gst)
      if (sales === 0 && potential === 0 && actual === 0 && asst === 0) continue
      out.push(r)
    }
    out.sort((a, b) => {
      const aw = String(a.pay_week_start ?? '')
      const bw = String(b.pay_week_start ?? '')
      return bw.localeCompare(aw)
    })
    return out
  }, [trend.data, weekStartSet])

  function buildPreviewSummaryRow(
    r: MySalesTrendWeeklyRow,
  ): WeeklyCommissionSummaryRow {
    /* Minimal shape the existing line-preview modal needs. location_id
     * is intentionally blank so the preview shows lines across all
     * locations for the pay week, matching the "combined across
     * locations" totals shown in the My Sales row. */
    return {
      pay_week_start: r.pay_week_start ?? null,
      pay_week_end: r.pay_week_end ?? null,
      pay_date: r.pay_date ?? null,
      location_id: null,
      location_name: null,
      derived_staff_paid_id: r.staff_member_id ?? null,
      derived_staff_paid_display_name: r.staff_display_name ?? null,
      derived_staff_paid_full_name: r.staff_full_name ?? null,
    }
  }

  /* --- render guards --- */

  if (accessState === 'loading' || trend.isLoading) {
    return (
      <div data-testid="payroll-summary-page">
        <PageHeader title="My Sales" />
        <LoadingState
          message="Loading your sales..."
          testId="payroll-summary-loading"
        />
      </div>
    )
  }

  if (trend.isError) {
    const { message, err } = queryErrorDetail(trend.error)
    return (
      <div data-testid="payroll-summary-page">
        <PageHeader title="My Sales" />
        <ErrorState
          title="Could not load your sales"
          error={err}
          message={message}
          onRetry={() => void trend.refetch()}
          testId="payroll-summary-error"
        />
      </div>
    )
  }

  if (myStaffId === '') {
    return (
      <div data-testid="payroll-summary-page">
        <PageHeader title="My Sales" />
        <EmptyState
          title="No staff profile linked to your account"
          description="My Sales is only available once your login is mapped to a staff member. Contact your manager if you think this is wrong."
          testId="payroll-summary-empty"
        />
      </div>
    )
  }

  const hasAnyData = tableRows.length > 0

  return (
    <div data-testid="payroll-summary-page">
      <PageHeader title="My Sales" />

      <section
        className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6"
        data-testid="my-sales-chart-card"
      >
        <StaffTrendsLineChart
          weekStarts={weekStarts}
          series={chartSeries}
          yMax={yMax}
          height={220}
          emptyMessage="No sales in the last 52 weeks."
        />
        <ul className="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-slate-700">
          {chartSeries.map((s) => (
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

      <section
        className="mt-4 rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6"
        data-testid="my-sales-weekly-breakdown"
      >
        <div className="mb-3 flex items-center justify-between">
          <h2 className="text-base font-semibold text-slate-800">
            Weekly breakdown
          </h2>
          <span className="text-xs text-slate-500">
            {tableRows.length} {tableRows.length === 1 ? 'row' : 'rows'}
          </span>
        </div>
        {!hasAnyData ? (
          <p className="text-sm text-slate-600">
            No sales for you in the last {WEEKS} weeks.
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
                    Role
                  </th>
                  <th scope="col" className="px-3 py-2">
                    Remuneration plan
                  </th>
                  <th scope="col" className="px-3 py-2 text-right">
                    Sales ex GST
                  </th>
                  <th scope="col" className="px-3 py-2 text-right">
                    Potential Comm. ex GST
                  </th>
                  <th scope="col" className="px-3 py-2 text-right">
                    Comm. ex GST
                  </th>
                  <th
                    scope="col"
                    className="px-3 py-2 text-right text-slate-400"
                  >
                    Assistant Comm. ex GST
                  </th>
                  <th scope="col" className="px-3 py-2 text-right">
                    Details
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {tableRows.map((r) => {
                  const w = String(r.pay_week_start ?? '')
                  const sales = parseNumOr0(r.total_sales_ex_gst)
                  const potential = parseNumOr0(
                    r.total_theoretical_commission_ex_gst,
                  )
                  const actual = parseNumOr0(r.total_actual_commission_ex_gst)
                  const asst = parseNumOr0(
                    r.total_assistant_commission_ex_gst,
                  )
                  const role = (r.effective_primary_role ?? '').trim()
                  const plan = (r.effective_remuneration_plan ?? '').trim()

                  const planLooksCommissionOrContractor =
                    isCommissionOrContractorPlan(plan)
                  const potentialIsRedundant =
                    sales === 0 ||
                    (planLooksCommissionOrContractor && potential === actual)
                  const potentialCellText = potentialIsRedundant
                    ? '-'
                    : formatNzd(potential)

                  const contributors = Array.isArray(
                    r.assistant_commission_contributors,
                  )
                    ? r.assistant_commission_contributors
                    : []

                  const fullReportHref = `/app/my-sales/${encodeURIComponent(w)}`

                  return (
                    <tr key={w}>
                      <td className="px-3 py-1.5 whitespace-nowrap text-slate-700">
                        {formatWeekLong(w)}
                      </td>
                      <td className="px-3 py-1.5 text-slate-700">
                        {role === '' ? '-' : role}
                      </td>
                      <td className="px-3 py-1.5 text-slate-700">
                        {plan === '' ? '-' : plan}
                      </td>
                      <td className="px-3 py-1.5 text-right tabular-nums text-slate-800">
                        {formatNzd(sales)}
                      </td>
                      <td className="px-3 py-1.5 text-right tabular-nums text-slate-800">
                        {potentialCellText}
                      </td>
                      <td className="px-3 py-1.5 text-right tabular-nums text-slate-800">
                        {formatNzd(actual)}
                      </td>
                      <td className="px-3 py-1.5 text-right tabular-nums text-slate-500">
                        <AssistantCommCell
                          amount={asst}
                          contributors={contributors}
                        />
                      </td>
                      <td className="px-3 py-1.5 text-right">
                        <Link
                          to={fullReportHref}
                          onClick={(e) => {
                            if (
                              e.ctrlKey ||
                              e.metaKey ||
                              e.shiftKey ||
                              e.altKey ||
                              e.button !== 0
                            ) {
                              return
                            }
                            e.preventDefault()
                            setPreviewRow(buildPreviewSummaryRow(r))
                          }}
                          className="font-medium text-violet-700 hover:text-violet-900 hover:underline"
                          data-testid={`my-sales-view-lines-${w}`}
                        >
                          View lines
                        </Link>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>

      <PayrollLinesPreviewModal
        summaryRow={previewRow}
        onClose={() => setPreviewRow(null)}
      />
    </div>
  )
}

/* ------------------------------------------------------------------ */
/* Assistant Comm. cell (muted text + contributor icons)                */
/* ------------------------------------------------------------------ */

function AssistantCommCell({
  amount,
  contributors,
}: {
  amount: number
  contributors: AssistantCommissionContributor[]
}) {
  /* Spec: $0.00 when null OR zero. formatNzd(0) returns "$0.00". */
  const safeAmount = amount > 0 ? amount : 0
  const formatted = formatNzd(safeAmount)

  if (safeAmount <= 0) {
    return <span>{formatted}</span>
  }

  /* Only show icons for contributors with a positive contribution; sort
   * alphabetically by display name so the visual order is deterministic
   * regardless of payload ordering. */
  const positive = contributors
    .filter((c) => parseNumOr0(c.amount_ex_gst) > 0)
    .sort((a, b) => {
      const an = (a.display_name ?? '').toString().toLowerCase()
      const bn = (b.display_name ?? '').toString().toLowerCase()
      return an.localeCompare(bn)
    })

  if (positive.length === 0) {
    /* Spec: total > 0 but no contributor breakdown -> amount only,
     * no invented icons. */
    return <span>{formatted}</span>
  }

  return (
    <span className="inline-flex items-center gap-1.5">
      <span className="inline-flex items-center -space-x-1">
        {positive.map((c, idx) => {
          const name = (c.display_name ?? '').toString().trim()
          const amt = parseNumOr0(c.amount_ex_gst)
          const bg = contributorColor(c)
          const label =
            name !== ''
              ? `${name} contributed ${formatNzd(amt)}`
              : 'Assistant contributor'
          const title = name !== '' ? `${name}: ${formatNzd(amt)}` : undefined
          return (
            <span
              key={contributorKey(c, idx)}
              title={title}
              aria-label={label}
              className="inline-flex h-4 w-4 items-center justify-center rounded-full text-[10px] font-semibold leading-none text-white ring-1 ring-white"
              style={{ background: bg }}
            >
              {assistantInitial(name)}
            </span>
          )
        })}
      </span>
      <span className="tabular-nums">{formatted}</span>
    </span>
  )
}
