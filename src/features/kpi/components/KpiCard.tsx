import type {
  KpiSnapshotRow,
  KpiStylistComparisonRow,
} from '@/features/kpi/data/kpiApi'
import {
  formatKpiSupporting,
  formatKpiValue,
  metaFor,
} from '@/features/kpi/kpiLabels'

/**
 * Per-KPI prefix for the "Avg ..." comparison pill, e.g. "Avg revenue"
 * → rendered as "Avg revenue (all salons): $3,634.04". This map also
 * acts as the display allow-list: any KPI not listed here renders no
 * comparison pills even if the backend sends a row.
 *
 * `average_client_spend` is special-cased to avoid the awkward
 * "Avg avg spend" phrasing — it reads "Average client spend" instead.
 *
 * Keep in lockstep with `public.get_kpi_stylist_comparisons_live`
 * (set-based migration adds assistant_utilisation_ratio alongside
 * revenue, guests, new clients, average spend).
 */
const COMPARISON_AVG_LABEL: Record<string, string> = {
  revenue: 'Avg revenue',
  guests_per_month: 'Avg guests',
  new_clients_per_month: 'Avg new guests',
  average_client_spend: 'Average guest spend',
  assistant_utilisation_ratio: 'Avg utilisation',
}

/**
 * KPIs for which FTE-based normalisation is meaningful. Volume-like
 * metrics (total revenue, total guests, total new clients) scale
 * linearly with time worked, so a 0.5 FTE stylist's raw numbers are
 * roughly half of a full-timer's — dividing by fte brings the display
 * onto a 1.0 FTE basis. Rate / ratio / retention KPIs are excluded on
 * purpose (they already normalise per-client or per-sale), as is
 * `stylist_profitability` which has its own $/FTE denominator.
 *
 * This set is intentionally narrow. Expand only after confirming the
 * underlying metric is a raw volume.
 */
const NORMALISABLE_KPI_CODES: ReadonlySet<string> = new Set([
  'revenue',
  'guests_per_month',
  'new_clients_per_month',
])

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
   * status marker at the start of the title row (gold star = highest,
   * green dot = above average, orange dot = below average) plus two
   * compact "Top / Avg [metric] (all salons)" pills centered at the
   * bottom of the card (pale gold for Top, pale green for Avg). The
   * main KPI value and supporting text stay left aligned — only the
   * pill block is centered. The headline number itself keeps the
   * default slate tone; the icon is the only status indicator. KPIs
   * without a comparison row render exactly as before.
   */
  comparison?: KpiStylistComparisonRow | null
  /**
   * Optional FTE for the current self/staff caller. When `fte` is a
   * finite number strictly between 0 and 1 AND the KPI is in
   * `NORMALISABLE_KPI_CODES`, the card displays the raw metric scaled
   * to a 1.0 FTE basis (value / fte), appends "(NORMALISED)" to the
   * title, and shows a muted "Raw: …" line under the main number.
   * Otherwise the card renders unchanged.
   *
   * The dashboard only sets this on non-elevated (stylist / assistant)
   * self/staff cards; elevated manager / admin views receive `null`
   * and are never normalised.
   */
  fte?: number | null
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
  fte = null,
}: KpiCardProps) {
  const meta = metaFor(row.kpi_code)

  // FTE normalisation. Only applied when the caller passed a finite
  // `fte` in the open interval (0, 1) AND the KPI is a raw-volume
  // metric (see `NORMALISABLE_KPI_CODES`). We multiply the raw value
  // by `1 / fte` so a 0.5 FTE stylist's number is effectively doubled,
  // a 0.8 FTE stylist's number is divided by 0.8, and so on. All
  // rendering is done via the existing `formatKpiValue` so currency /
  // count formatting stays consistent.
  const rawValueNumber =
    row.value == null
      ? null
      : typeof row.value === 'number'
        ? row.value
        : Number(row.value)
  const rawValueFinite =
    rawValueNumber != null && Number.isFinite(rawValueNumber)
      ? rawValueNumber
      : null
  const shouldNormalise =
    NORMALISABLE_KPI_CODES.has(row.kpi_code) &&
    fte != null &&
    Number.isFinite(fte) &&
    fte > 0 &&
    fte < 1 &&
    rawValueFinite != null
  const displayedValue = shouldNormalise
    ? rawValueFinite! / (fte as number)
    : row.value
  const valueText = formatKpiValue(meta.format, displayedValue)
  const rawValueText = shouldNormalise
    ? formatKpiValue(meta.format, row.value)
    : null
  const titleText = shouldNormalise ? `${meta.label} (NORMALISED)` : meta.label
  const supporting = formatKpiSupporting(
    meta.format,
    row.value_numerator,
    row.value_denominator,
  )

  // Per-KPI prefix for the "Avg ..." pill. The map doubles as the
  // comparison-eligibility gate on the display side: any KPI not
  // listed here will never render pills even if the backend sends a
  // row for it. KPIs outside this set (e.g. retentions,
  // stylist_profitability) stay without pills. The top pill label is a
  // fixed "Top Stylist" string for every supported KPI so it doesn't
  // need a per-KPI entry.
  const comparisonAvgLabel = COMPARISON_AVG_LABEL[row.kpi_code]

  // Show the two-line "Highest stylist X / Average stylist X" note
  // whenever the backend returned a comparison row with a meaningful
  // `highest_value` AND the KPI is in the comparison-eligible set.
  // The backend itself already gates `is_highest` / `is_above_average`
  // on `cohort_size >= 2`, so the tint stays correctly off for
  // single-stylist cohorts without needing a second frontend gate.
  // For revenue / guests / new_clients, the RPC uses FTE-adjusted
  // cohort values when 0 < fte < 1 so flags and pills match the
  // normalised headline number on the card.
  const showComparison =
    !!comparison &&
    !!comparisonAvgLabel &&
    comparison.highest_value != null

  // Status marker shown at the start of the title row. Same precedence
  // as the retired value tint: highest > above average > below average.
  // `null` when there is no comparison to show — keeps title row
  // visually identical for business / location / unsupported-KPI cards.
  const comparisonStatus: 'highest' | 'above' | 'below' | null = showComparison
    ? comparison?.is_highest
      ? 'highest'
      : comparison?.is_above_average
        ? 'above'
        : 'below'
    : null

  const comparisonIcon =
    comparisonStatus === 'highest' ? (
      <span
        aria-hidden="true"
        className="shrink-0 text-sm leading-none text-amber-400"
        data-testid={`kpi-card-status-${row.kpi_code}`}
      >
        ★
      </span>
    ) : comparisonStatus === 'above' ? (
      <span
        aria-hidden="true"
        className="inline-block h-2 w-2 shrink-0 rounded-full bg-emerald-500"
        data-testid={`kpi-card-status-${row.kpi_code}`}
      />
    ) : comparisonStatus === 'below' ? (
      <span
        aria-hidden="true"
        className="inline-block h-2 w-2 shrink-0 rounded-full bg-orange-500"
        data-testid={`kpi-card-status-${row.kpi_code}`}
      />
    ) : null

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
      <div className="flex min-w-0 items-center gap-1.5">
        {comparisonIcon}
        <p className="min-w-0 truncate text-[11px] font-semibold uppercase tracking-wide text-slate-500">
          {titleText}
        </p>
      </div>
      {/*
        Reserved min-height keeps the main KPI value row aligned
        horizontally across cards in the same grid row, even when one
        description wraps onto a second line (e.g. "New clients") and
        another fits on one (e.g. "Revenue"). Tuned for up to 2 lines
        at `text-xs leading-snug`; longer-description KPIs naturally
        sit in other rows.
      */}
      <p className="mt-1.5 min-h-[2.5rem] text-xs leading-snug text-slate-500">
        {meta.description ?? ''}
      </p>
      <p className="mt-3 truncate text-2xl font-semibold text-slate-900 sm:text-3xl">
        {valueText}
      </p>
      {rawValueText ? (
        <p
          className="mt-1 truncate text-[11px] font-medium text-slate-400"
          data-testid={`kpi-card-raw-${row.kpi_code}`}
        >
          {`Raw: ${rawValueText}`}
        </p>
      ) : null}
      {supporting ? (
        <p className="mt-1.5 truncate text-xs font-medium text-slate-600">
          {supporting}
        </p>
      ) : null}
      {showComparison ? (
        <div
          className="mt-auto flex flex-col items-stretch gap-1 pt-3"
          data-testid={`kpi-card-comparison-${row.kpi_code}`}
        >
          <span className="block w-full truncate rounded-full bg-amber-50 px-3 py-0.5 text-center text-[11px] font-medium text-slate-700 ring-1 ring-inset ring-amber-100">
            {`Top Stylist (all salons): ${formatKpiValue(
              meta.format,
              comparison.highest_value,
            )}`}
          </span>
          <span className="block w-full truncate rounded-full bg-emerald-50 px-3 py-0.5 text-center text-[11px] font-medium text-slate-700 ring-1 ring-inset ring-emerald-100">
            {`${comparisonAvgLabel} (all salons): ${formatKpiValue(
              meta.format,
              comparison.average_value,
            )}`}
          </span>
        </div>
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
