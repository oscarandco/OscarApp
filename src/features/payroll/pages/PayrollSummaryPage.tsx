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
  potentialAssistant: '#65a30d',
}
const METRIC_LABELS = {
  sales: 'Sales ex GST',
  potential: 'Potential commission ex GST',
  actual: 'Actual commission ex GST',
  potentialAssistant: 'Potential assistant commission ex GST',
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

/**
 * Mobile-only compact week label: "25 May '26", "4 May '26",
 * "16 Feb '26". Drops the weekday and uses a two-digit year so the
 * Week column fits comfortably on a phone-width viewport without
 * needing horizontal scroll. Desktop continues to use formatWeekLong.
 */
function formatWeekShort(iso: string): string {
  const d = parseUtcDate(iso)
  if (!d) return iso
  const day = d.getUTCDate()
  const month = d.toLocaleDateString('en-NZ', {
    month: 'short',
    timeZone: 'UTC',
  })
  const year = String(d.getUTCFullYear()).slice(-2)
  return `${day} ${month} '${year}`
}

/**
 * Mobile-only "Role / Plan" merge: e.g. "Stylist - Wage",
 * "Assistant - Wage", "Director Stylist - Commission",
 * "Contractor - Contractor 45%". Uses a normal hyphen with spaces
 * around it (no em dash). Falls back to whichever side is populated;
 * shows "-" if both are empty so the cell isn't visually blank.
 */
function formatRolePlanMobile(
  role: string | null | undefined,
  plan: string | null | undefined,
): string {
  const r = (role ?? '').trim()
  const p = (plan ?? '').trim()
  if (r !== '' && p !== '') return `${r} - ${p}`
  if (r !== '') return r
  if (p !== '') return p
  return '-'
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

/**
 * Wage remuneration plan (case-insensitive, exact match on the canonical
 * label "Wage"). Potential Assistant Comm. is only meaningful for wage
 * stylists, because for commission / contractor stylists the theoretical
 * assistant total equals the actual assistant total (same rate, same
 * plan), so adding the column would just duplicate Assistant Comm.
 */
function isWagePlan(plan: string | null | undefined): boolean {
  const p = (plan ?? '').trim().toLowerCase()
  return p === 'wage'
}

/**
 * Assistant-like primary role: Assistant, Apprentice, Junior Apprentice,
 * Senior Assistant, etc. Used to suppress the Assistant Comm. column on
 * weeks where the logged-in person was the assistant on the job: they
 * are the work staff, not a stylist paying out assistant commission to
 * someone else, so an assistant icon there would be misleading. Their
 * Actual Comm. ex GST still shows the real amount they earned.
 *
 * Case-insensitive substring match keeps this future-proof for new
 * role labels added in Staff Admin.
 */
function isAssistantLikeRole(role: string | null | undefined): boolean {
  const r = (role ?? '').trim().toLowerCase()
  if (r === '') return false
  return r.includes('assistant') || r.includes('apprentice')
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

  /* "Potential commission" is only useful when it differs from the
   * actual commission earned for at least one visible weekly row. For
   * staff who have been on a Commission / Contractor plan the whole
   * 52 week window, potential equals actual every week and the
   * Potential line just duplicates the Actual line on the chart while
   * the table column is always "-". In that case we drop the series /
   * column entirely. The 0.005 tolerance avoids false-meaningful flips
   * from $0.001-ish rounding noise between potential and actual. */
  const hasMeaningfulPotentialCommission = useMemo(() => {
    for (const r of tableRows) {
      const sales = parseNumOr0(r.total_sales_ex_gst)
      const potential = parseNumOr0(r.total_theoretical_commission_ex_gst)
      const actual = parseNumOr0(r.total_actual_commission_ex_gst)
      if (
        sales > 0 &&
        potential > 0 &&
        Math.abs(potential - actual) > 0.005
      ) {
        return true
      }
    }
    return false
  }, [tableRows])

  /* "Actual Assistant Comm." is only meaningful when at least one
   * visible weekly row is a non-assistant-like role with actual
   * assistant commission > 0. Assistant-like rows never have meaningful
   * actual assistant commission for THIS person (they are the assistant
   * on the job, not paying out to one), and a stylist with no actual
   * assistant commission across all visible weeks gets the whole
   * column hidden so the table stops showing a wall of $0.00. */
  const hasMeaningfulActualAssistantCommission = useMemo(() => {
    for (const r of tableRows) {
      const role = (r.effective_primary_role ?? '').trim()
      if (isAssistantLikeRole(role)) continue
      const asst = parseNumOr0(r.total_assistant_commission_ex_gst)
      if (asst > 0) return true
    }
    return false
  }, [tableRows])

  /* "Potential Assistant Comm." is only meaningful for wage stylists
   * where there were sales and the line-level theoretical assistant
   * commission calculation found at least some assistant-eligible
   * work. Assistant-like rows are excluded because the value is
   * conceptually about what assistant commission WOULD have applied
   * to OTHER staff helping this stylist - it's irrelevant when the
   * person IS the assistant. Commission / contractor rows are
   * excluded because, by construction, their theoretical assistant
   * commission equals their actual assistant commission and the
   * column would duplicate Assistant Comm. */
  const hasMeaningfulPotentialAssistantCommission = useMemo(() => {
    for (const r of tableRows) {
      const role = (r.effective_primary_role ?? '').trim()
      const plan = (r.effective_remuneration_plan ?? '').trim()
      if (isAssistantLikeRole(role)) continue
      if (!isWagePlan(plan)) continue
      const sales = parseNumOr0(r.total_sales_ex_gst)
      const pAsst = parseNumOr0(r.total_theoretical_assistant_commission_ex_gst)
      if (sales > 0 && pAsst > 0) return true
    }
    return false
  }, [tableRows])

  /* Same zero-week-gap treatment as Sales / Potential / Actual so the
   * Potential Assistant line goes to a gap on Christmas-shutdown weeks
   * instead of plunging to $0 and back. */
  const displayPotentialAssistant = useMemo(() => {
    const out: (number | null)[] = new Array(WEEKS)
    weekStarts.forEach((w, i) => {
      const r = rowByWeek.get(w)
      const s = parseNumOr0(r?.total_sales_ex_gst)
      const p = parseNumOr0(r?.total_theoretical_commission_ex_gst)
      const a = parseNumOr0(r?.total_actual_commission_ex_gst)
      const pAsst = parseNumOr0(
        r?.total_theoretical_assistant_commission_ex_gst,
      )
      if (s === 0 && p === 0 && a === 0 && pAsst === 0) {
        out[i] = null
      } else {
        out[i] = pAsst
      }
    })
    return out
  }, [weekStarts, rowByWeek])

  /* Build the chart series in the order the user sees them in the
   * legend / tooltip. When the Potential or Potential Assistant lines
   * are hidden the series shrinks; the legend and the chart tooltip
   * both iterate this array so neither needs a separate hide branch. */
  const chartSeries = useMemo<StaffTrendsSeries[]>(() => {
    const out: StaffTrendsSeries[] = [
      {
        id: 'sales',
        label: METRIC_LABELS.sales,
        color: METRIC_COLORS.sales,
        values: displaySales,
      },
    ]
    if (hasMeaningfulPotentialCommission) {
      out.push({
        id: 'potential',
        label: METRIC_LABELS.potential,
        color: METRIC_COLORS.potential,
        values: displayPotential,
      })
    }
    if (hasMeaningfulPotentialAssistantCommission) {
      out.push({
        id: 'potentialAssistant',
        label: METRIC_LABELS.potentialAssistant,
        color: METRIC_COLORS.potentialAssistant,
        values: displayPotentialAssistant,
      })
    }
    out.push({
      id: 'actual',
      label: METRIC_LABELS.actual,
      color: METRIC_COLORS.actual,
      values: displayActual,
    })
    return out
  }, [
    hasMeaningfulPotentialCommission,
    hasMeaningfulPotentialAssistantCommission,
    displaySales,
    displayPotential,
    displayPotentialAssistant,
    displayActual,
  ])

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
                  {/* Week beginning. Header label and date format both
                      collapse on mobile: header "Week", body "25 May '26".
                      Desktop continues to show "Week beginning" and the
                      long "Mon, 25 May 2026" date. */}
                  <th scope="col" className="px-2 py-2 sm:px-3">
                    <span className="sm:hidden">Week</span>
                    <span className="hidden sm:inline">Week beginning</span>
                  </th>
                  {/* Mobile-only merged Role / Plan column. Hidden from
                      sm: up so the desktop Role + Remuneration plan
                      columns take over. */}
                  <th
                    scope="col"
                    className="px-2 py-2 sm:hidden"
                  >
                    Role / Plan
                  </th>
                  {/* Desktop-only Role column. */}
                  <th
                    scope="col"
                    className="hidden px-3 py-2 sm:table-cell"
                  >
                    Role
                  </th>
                  {/* Desktop-only Remuneration plan column. */}
                  <th
                    scope="col"
                    className="hidden px-3 py-2 sm:table-cell"
                  >
                    Remuneration plan
                  </th>
                  <th
                    scope="col"
                    className="px-2 py-2 text-right sm:px-3"
                  >
                    Sales ex GST
                  </th>
                  <th
                    scope="col"
                    className="px-2 py-2 text-right sm:px-3"
                  >
                    <span className="sm:hidden">Actual Comm.</span>
                    <span className="hidden sm:inline">
                      Actual Comm. ex GST
                    </span>
                  </th>
                  {hasMeaningfulActualAssistantCommission ? (
                    <th
                      scope="col"
                      className="px-2 py-2 text-right text-slate-400 sm:px-3"
                    >
                      <span className="sm:hidden">Assist. Comm.</span>
                      <span className="hidden sm:inline">
                        Assistant Comm. ex GST
                      </span>
                    </th>
                  ) : null}
                  {hasMeaningfulPotentialCommission ? (
                    <th
                      scope="col"
                      className="px-2 py-2 text-right text-slate-400 sm:px-3"
                    >
                      <span className="sm:hidden">Potential Comm.</span>
                      <span className="hidden sm:inline">
                        Potential Comm. ex GST
                      </span>
                    </th>
                  ) : null}
                  {hasMeaningfulPotentialAssistantCommission ? (
                    <th
                      scope="col"
                      className="px-2 py-2 text-right text-slate-400 sm:px-3"
                    >
                      <span className="sm:hidden">Pot. Assist. Comm.</span>
                      <span className="hidden sm:inline">
                        Potential Assistant Comm. ex GST
                      </span>
                    </th>
                  ) : null}
                  <th
                    scope="col"
                    className="px-2 py-2 text-right sm:px-3"
                  >
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
                  const pAsst = parseNumOr0(
                    r.total_theoretical_assistant_commission_ex_gst,
                  )
                  const role = (r.effective_primary_role ?? '').trim()
                  const plan = (r.effective_remuneration_plan ?? '').trim()
                  const assistantLikeRow = isAssistantLikeRole(role)
                  const wagePlanRow = isWagePlan(plan)

                  const planLooksCommissionOrContractor =
                    isCommissionOrContractorPlan(plan)
                  const potentialIsRedundant =
                    sales === 0 ||
                    (planLooksCommissionOrContractor && potential === actual)
                  const potentialCellText = potentialIsRedundant
                    ? '-'
                    : formatNzd(potential)

                  /* Per-row Potential Assistant Comm. rule:
                   *   * Assistant-like rows: always "-" (column shown
                   *     only because a non-assistant row needed it).
                   *   * Non-wage rows (Commission / Contractor / other):
                   *     "-" - theoretical assistant equals actual
                   *     assistant for these rows and would just
                   *     duplicate the Assistant Comm. column.
                   *   * No sales / zero potential: "-".
                   *   * Otherwise: the formatted dollar amount. */
                  const potentialAssistantIsMeaningfulForRow =
                    !assistantLikeRow && wagePlanRow && sales > 0 && pAsst > 0
                  const potentialAssistantCellText =
                    potentialAssistantIsMeaningfulForRow
                      ? formatNzd(pAsst)
                      : '-'

                  const contributors = Array.isArray(
                    r.assistant_commission_contributors,
                  )
                    ? r.assistant_commission_contributors
                    : []

                  const fullReportHref = `/app/my-sales/${encodeURIComponent(w)}`

                  return (
                    <tr key={w}>
                      <td className="px-2 py-1.5 whitespace-nowrap text-slate-700 sm:px-3">
                        <span className="sm:hidden">
                          {formatWeekShort(w)}
                        </span>
                        <span className="hidden sm:inline">
                          {formatWeekLong(w)}
                        </span>
                      </td>
                      {/* Mobile-only merged Role / Plan cell. */}
                      <td className="px-2 py-1.5 text-slate-700 sm:hidden">
                        {formatRolePlanMobile(role, plan)}
                      </td>
                      {/* Desktop-only Role cell. */}
                      <td className="hidden px-3 py-1.5 text-slate-700 sm:table-cell">
                        {role === '' ? '-' : role}
                      </td>
                      {/* Desktop-only Remuneration plan cell. */}
                      <td className="hidden px-3 py-1.5 text-slate-700 sm:table-cell">
                        {plan === '' ? '-' : plan}
                      </td>
                      <td className="px-2 py-1.5 text-right tabular-nums text-slate-800 sm:px-3">
                        {formatNzd(sales)}
                      </td>
                      <td className="px-2 py-1.5 text-right tabular-nums text-slate-800 sm:px-3">
                        {formatNzd(actual)}
                      </td>
                      {hasMeaningfulActualAssistantCommission ? (
                        <td className="px-2 py-1.5 text-right tabular-nums text-slate-500 sm:px-3">
                          <AssistantCommCell
                            amount={asst}
                            contributors={contributors}
                            isAssistantLike={assistantLikeRow}
                          />
                        </td>
                      ) : null}
                      {hasMeaningfulPotentialCommission ? (
                        <td className="px-2 py-1.5 text-right tabular-nums text-slate-500 sm:px-3">
                          {potentialCellText}
                        </td>
                      ) : null}
                      {hasMeaningfulPotentialAssistantCommission ? (
                        <td className="px-2 py-1.5 text-right tabular-nums text-slate-500 sm:px-3">
                          {potentialAssistantCellText}
                        </td>
                      ) : null}
                      <td className="px-2 py-1.5 text-right sm:px-3">
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
                          <span className="sm:hidden">View</span>
                          <span className="hidden sm:inline">View lines</span>
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
/* Assistant Comm. cell (muted text + contributor icons + alignment)    */
/* ------------------------------------------------------------------ */

/**
 * Fixed-width inline-grid wrapper that keeps the dollar sign at the
 * same X position on every row of the Assistant Comm. column. The icon
 * slot is rendered with a constant width even when empty (or when the
 * row is suppressed because the staff member was the assistant on the
 * job), so the amount text never shifts horizontally.
 */
function AssistantCommSlots({
  icons,
  text,
}: {
  icons: React.ReactNode
  text: string
}) {
  return (
    <span className="inline-grid grid-cols-[2.75rem_4rem] items-center gap-2">
      <span
        aria-hidden={icons == null ? true : undefined}
        className="inline-flex items-center justify-end -space-x-1"
      >
        {icons}
      </span>
      <span className="text-left tabular-nums">{text}</span>
    </span>
  )
}

function AssistantCommCell({
  amount,
  contributors,
  isAssistantLike,
}: {
  amount: number
  contributors: AssistantCommissionContributor[]
  isAssistantLike: boolean
}) {
  /* Assistant-like rows: the person IS the assistant on the job, so
   * showing assistant-attributed commission and icons here is
   * misleading. Display a dash; Actual Comm. ex GST still shows the
   * real amount they earned. */
  if (isAssistantLike) {
    return <AssistantCommSlots icons={null} text="-" />
  }

  /* Spec: $0.00 when null OR zero. formatNzd(0) returns "$0.00". */
  const safeAmount = amount > 0 ? amount : 0
  const formatted = formatNzd(safeAmount)

  if (safeAmount <= 0) {
    return <AssistantCommSlots icons={null} text={formatted} />
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
    return <AssistantCommSlots icons={null} text={formatted} />
  }

  const icons = positive.map((c, idx) => {
    const name = (c.display_name ?? '').toString().trim()
    const amt = parseNumOr0(c.amount_ex_gst)
    const bg = contributorColor(c)
    const label =
      name !== ''
        ? `${name} contributed ${formatNzd(amt)}`
        : 'Assistant contributor'
    /* Hover tooltip shows the assistant's display name (and amount when
     * available, per spec). Browsers render `title` on hover and most
     * screen readers prefer `aria-label`. */
    const title =
      name !== '' ? `${name} (${formatNzd(amt)})` : 'Assistant contributor'
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
  })

  return <AssistantCommSlots icons={icons} text={formatted} />
}
