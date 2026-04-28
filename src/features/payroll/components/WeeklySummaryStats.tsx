import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { formatNzd } from '@/lib/formatters'

/**
 * Pre-computed extra tile rendered after the built-in cards. Used by My
 * Sales to add per-location SALES (EX GST) tiles alongside the existing
 * Pay Weeks / Commission cards while keeping the same responsive grid.
 */
export type WeeklySummaryExtraTile = {
  key: string
  label: string
  /** Already-summed money value (NZD ex GST) or `null` when unknown. */
  value: number | null
}

type WeeklySummaryStatsProps = {
  /** Rows currently shown in the table (after client-side filters). */
  rows: WeeklyCommissionSummaryRow[]
  /** Admin weekly payroll: toggle “unconfigured paid staff” table filter from the warning banner. */
  unconfiguredFilterProps?: {
    active: boolean
    onToggle: () => void
  }
  /**
   * Override for the "Pay weeks" card label. Defaults to `Pay weeks`
   * so existing callers (e.g. AdminPayrollSummaryPage) render the same
   * label as before. My Sales overrides this to `Number of weeks shown`.
   */
  weeksCardLabel?: string
  /**
   * Override for the commission card label. Defaults to `Commission`.
   * My Sales passes `Commission earnt`. The underlying value is always
   * sourced from `total_actual_commission_ex_gst` (Actual Commission
   * ex GST), never the theoretical/potential figure.
   */
  commissionCardLabel?: string
  /** Mount the commission card. Defaults to `true`. Apprentice hides it. */
  showCommissionCard?: boolean
  /** Mount the sales (ex GST) card. Defaults to `true`. Stylist + apprentice hide it. */
  showSalesCard?: boolean
  /**
   * Mount the "Rows shown" meta card. Defaults to `true` so existing
   * callers (e.g. AdminPayrollSummaryPage) keep showing it. My Sales
   * passes `false` for stylist + assistant — the same figure is
   * already in the diagnostics line above the table.
   */
  showRowsShownCard?: boolean
  /**
   * Optional pre-computed money tiles rendered after the built-in
   * cards. My Sales uses this to add per-location `SALES (EX GST) -
   * <LOCATION>` tiles. Each tile is already summed by the caller (so
   * the math reflects whatever scope the page deems correct, e.g.
   * date-range only). Empty / undefined = no extra tiles.
   */
  extraTiles?: WeeklySummaryExtraTile[]
}

function sumActualCommission(rows: WeeklyCommissionSummaryRow[]): number | null {
  let total = 0
  let found = false
  for (const r of rows) {
    const v = r.total_actual_commission_ex_gst ?? r.total_actual_commission
    if (v != null && v !== '') {
      const n = typeof v === 'number' ? v : Number(v)
      if (!Number.isNaN(n)) {
        total += n
        found = true
      }
    }
  }
  return found ? total : null
}

function sumSalesExGst(rows: WeeklyCommissionSummaryRow[]): number | null {
  let total = 0
  let found = false
  for (const r of rows) {
    const v = r.total_sales_ex_gst
    if (v != null && v !== '') {
      const n = typeof v === 'number' ? v : Number(v)
      if (!Number.isNaN(n)) {
        total += n
        found = true
      }
    }
  }
  return found ? total : null
}

function distinctPayWeeks(rows: WeeklyCommissionSummaryRow[]): number {
  const set = new Set<string>()
  for (const r of rows) {
    const w = r.pay_week_start
    if (w != null && String(w).trim() !== '') {
      set.add(String(w).trim())
    }
  }
  return set.size
}

function anyUnconfigured(rows: WeeklyCommissionSummaryRow[]): boolean {
  return rows.some((r) => r.has_unconfigured_paid_staff_rows === true)
}

export function WeeklySummaryStats({
  rows,
  unconfiguredFilterProps,
  weeksCardLabel = 'Pay weeks',
  commissionCardLabel = 'Commission',
  showCommissionCard = true,
  showSalesCard = true,
  showRowsShownCard = true,
  extraTiles,
}: WeeklySummaryStatsProps) {
  const weeks = distinctPayWeeks(rows)
  const commission = sumActualCommission(rows)
  const sales = sumSalesExGst(rows)
  const warnUnconfigured = anyUnconfigured(rows)

  return (
    <div className="space-y-3" data-testid="weekly-summary-stats">
      {/* On mobile, the two meta stats (Pay weeks, Rows shown) are hidden
          because the same figures are already visible in the diagnostics
          line above the table. The two money cards get a denser
          2-up layout with tighter padding and smaller type so they fit
          one row on phone width. Desktop stays on the original 4-up
          layout at `xl`. */}
      <div className="grid grid-cols-2 gap-2 sm:gap-3 xl:grid-cols-4">
        <div className="hidden rounded-lg border border-slate-200 bg-white px-4 py-3 shadow-sm sm:block">
          <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
            {weeksCardLabel}
          </p>
          <p className="mt-1 text-2xl font-semibold tabular-nums text-slate-900">
            {weeks}
          </p>
        </div>
        {showRowsShownCard ? (
          <div className="hidden rounded-lg border border-slate-200 bg-white px-4 py-3 shadow-sm sm:block">
            <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
              Rows shown
            </p>
            <p className="mt-1 text-2xl font-semibold tabular-nums text-slate-900">
              {rows.length}
            </p>
          </div>
        ) : null}
        {showCommissionCard ? (
          <div className="rounded-lg border border-slate-200 bg-white px-3 py-2 shadow-sm sm:px-4 sm:py-3">
            <p className="text-[11px] font-medium uppercase tracking-wide text-slate-500 sm:text-xs">
              {commissionCardLabel}
            </p>
            <p className="mt-0.5 text-lg font-semibold tabular-nums text-slate-900 sm:mt-1 sm:text-2xl">
              {commission != null ? formatNzd(commission) : '—'}
            </p>
          </div>
        ) : null}
        {showSalesCard ? (
          <div className="rounded-lg border border-slate-200 bg-white px-3 py-2 shadow-sm sm:px-4 sm:py-3">
            <p className="text-[11px] font-medium uppercase tracking-wide text-slate-500 sm:text-xs">
              Sales (ex GST)
            </p>
            <p className="mt-0.5 text-lg font-semibold tabular-nums text-slate-900 sm:mt-1 sm:text-2xl">
              {sales != null ? formatNzd(sales) : '—'}
            </p>
          </div>
        ) : null}
        {extraTiles?.map((tile) => (
          <div
            key={tile.key}
            className="rounded-lg border border-slate-200 bg-white px-3 py-2 shadow-sm sm:px-4 sm:py-3"
            data-testid={`weekly-summary-extra-tile-${tile.key}`}
          >
            <p className="text-[11px] font-medium uppercase tracking-wide text-slate-500 sm:text-xs">
              {tile.label}
            </p>
            <p className="mt-0.5 text-lg font-semibold tabular-nums text-slate-900 sm:mt-1 sm:text-2xl">
              {tile.value != null ? formatNzd(tile.value) : '—'}
            </p>
          </div>
        ))}
      </div>
      {warnUnconfigured ? (
        <div
          className="flex flex-wrap items-center gap-2 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950"
          data-testid="weekly-summary-unconfigured-warning"
          role="status"
        >
          <p className="min-w-0 flex-1">
            <span className="font-medium">Unconfigured staff: </span>
            At least one displayed row includes unconfigured paid staff lines. Confirm
            setup in the salon admin process; excluded rows may not appear in stylist
            views.
          </p>
          {unconfiguredFilterProps ? (
            <button
              type="button"
              className={`shrink-0 rounded-md border px-3 py-1 text-xs font-medium transition focus:outline-none focus-visible:ring-2 focus-visible:ring-amber-500 focus-visible:ring-offset-2 ${
                unconfiguredFilterProps.active
                  ? 'border-amber-600 bg-amber-200 text-amber-950'
                  : 'border-amber-300 bg-white text-amber-900 hover:bg-amber-100/90'
              }`}
              aria-pressed={unconfiguredFilterProps.active}
              onClick={unconfiguredFilterProps.onToggle}
              data-testid="weekly-summary-unconfigured-filter-toggle"
            >
              Filter
            </button>
          ) : null}
        </div>
      ) : null}
    </div>
  )
}
