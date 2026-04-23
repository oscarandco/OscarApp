import type { KpiSnapshotRow } from '@/features/kpi/data/kpiApi'
import {
  formatKpiSupporting,
  formatKpiValue,
  metaFor,
} from '@/features/kpi/kpiLabels'

type KpiCardProps = {
  row: KpiSnapshotRow
  selected?: boolean
  onSelect?: (kpiCode: string) => void
}

/**
 * Compact KPI card used in the dashboard grid. When `onSelect` is
 * provided the card renders as a pressable `<button>` with a subtle
 * violet ring when `selected` — it drives the diagnostic detail
 * panel below the grid. Mobile-safe: the grid parent stacks to one
 * column on small screens, so the card does not need its own
 * breakpoint logic.
 */
export function KpiCard({ row, selected = false, onSelect }: KpiCardProps) {
  const meta = metaFor(row.kpi_code)
  const valueText = formatKpiValue(meta.format, row.value)
  const supporting = formatKpiSupporting(
    meta.format,
    row.value_numerator,
    row.value_denominator,
  )

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
      <p className="mt-3 truncate text-2xl font-semibold text-slate-900 sm:text-3xl">
        {valueText}
      </p>
      {supporting ? (
        <p className="mt-1.5 truncate text-xs font-medium text-slate-600">
          {supporting}
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
