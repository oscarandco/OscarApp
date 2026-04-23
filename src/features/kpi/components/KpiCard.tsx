import type {
  KpiSnapshotRow,
  KpiStylistComparisonRow,
} from '@/features/kpi/data/kpiApi'
import {
  formatKpiSupporting,
  formatKpiValue,
  metaFor,
} from '@/features/kpi/kpiLabels'

type KpiCardProps = {
  row: KpiSnapshotRow
  selected?: boolean
  onSelect?: (kpiCode: string) => void
  /**
   * Optional stylist comparison row for the same `kpi_code`. Only
   * passed in by the dashboard when the resolved scope is staff/self
   * AND the KPI is in the comparison-eligible set returned by
   * `public.get_kpi_stylist_comparisons_live`. When present and the
   * cohort has at least 2 contributors, the card renders a small
   * "Highest / Avg" line and tints the headline value (gold = highest,
   * green = above average). KPIs without a comparison row render
   * exactly as before.
   */
  comparison?: KpiStylistComparisonRow | null
}

/**
 * Compact KPI card used in the dashboard grid. When `onSelect` is
 * provided the card renders as a pressable `<button>` with a subtle
 * violet ring when `selected` — it drives the diagnostic detail
 * panel below the grid. Mobile-safe: the grid parent stacks to one
 * column on small screens, so the card does not need its own
 * breakpoint logic.
 */
export function KpiCard({
  row,
  selected = false,
  onSelect,
  comparison = null,
}: KpiCardProps) {
  const meta = metaFor(row.kpi_code)
  const valueText = formatKpiValue(meta.format, row.value)
  const supporting = formatKpiSupporting(
    meta.format,
    row.value_numerator,
    row.value_denominator,
  )

  // Comparison only renders when the backend returned a row AND the
  // cohort has at least one other stylist with a comparable value.
  // The backend already gates `is_highest` / `is_above_average` on
  // `cohort_size >= 2`, but we still hide the line below that to
  // keep the card honest ("Highest: $X" against a single-stylist
  // cohort would be misleading).
  const cohortSize = comparison ? Number(comparison.cohort_size) : 0
  const showComparison = !!comparison && cohortSize >= 2
  const valueToneClass = showComparison
    ? comparison.is_highest
      ? 'text-amber-500'
      : comparison.is_above_average
        ? 'text-emerald-600'
        : 'text-slate-900'
    : 'text-slate-900'

  const base =
    'flex min-w-0 flex-col rounded-lg border bg-white p-5 shadow-sm text-left transition-colors'
  const stateClasses = selected
    ? 'border-violet-400 ring-2 ring-violet-400/60'
    : 'border-slate-200'
  const interactive = onSelect
    ? 'cursor-pointer hover:border-slate-300 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500'
    : ''
  const className = [base, stateClasses, interactive]
    .filter(Boolean)
    .join(' ')

  const body = (
    <>
      <p className="truncate text-[11px] font-semibold uppercase tracking-wide text-slate-500">
        {meta.label}
      </p>
      {meta.description ? (
        <p className="mt-1.5 text-xs leading-snug text-slate-500">
          {meta.description}
        </p>
      ) : null}
      <p
        className={`mt-3 truncate text-2xl font-semibold sm:text-3xl ${valueToneClass}`}
      >
        {valueText}
      </p>
      {supporting ? (
        <p className="mt-1.5 truncate text-xs font-medium text-slate-600">
          {supporting}
        </p>
      ) : null}
      {showComparison ? (
        <p
          className="mt-1 truncate text-[11px] font-medium text-slate-500"
          data-testid={`kpi-card-comparison-${row.kpi_code}`}
        >
          {`Highest: ${formatKpiValue(
            meta.format,
            comparison.highest_value,
          )} · Avg: ${formatKpiValue(meta.format, comparison.average_value)}`}
        </p>
      ) : null}
    </>
  )

  if (onSelect) {
    return (
      <button
        type="button"
        onClick={() => onSelect(row.kpi_code)}
        aria-pressed={selected}
        className={className}
        data-testid={`kpi-card-${row.kpi_code}`}
      >
        {body}
      </button>
    )
  }

  return (
    <div className={className} data-testid={`kpi-card-${row.kpi_code}`}>
      {body}
    </div>
  )
}
