import type { KpiSnapshotRow } from '@/features/kpi/data/kpiApi'
import {
  formatKpiSupporting,
  formatKpiValue,
  metaFor,
} from '@/features/kpi/kpiLabels'

/**
 * Compact KPI card used in the dashboard grid. Mobile-safe: the grid
 * parent stacks to one column on small screens, so the card does not
 * need its own breakpoint logic. Value typography scales slightly on
 * `sm:` so desktop cards feel more prominent without hurting phone
 * readability.
 */
export function KpiCard({ row }: { row: KpiSnapshotRow }) {
  const meta = metaFor(row.kpi_code)
  const valueText = formatKpiValue(meta.format, row.value)
  const supporting = formatKpiSupporting(
    meta.format,
    row.value_numerator,
    row.value_denominator,
  )

  return (
    <div
      className="flex min-w-0 flex-col rounded-lg border border-slate-200 bg-white px-4 py-3"
      data-testid={`kpi-card-${row.kpi_code}`}
    >
      <p className="truncate text-[11px] font-semibold uppercase tracking-wide text-slate-500">
        {meta.label}
      </p>
      <p className="mt-1 truncate text-xl font-semibold text-slate-900 sm:text-2xl">
        {valueText}
      </p>
      {supporting ? (
        <p className="mt-1 truncate text-xs text-slate-500">{supporting}</p>
      ) : null}
    </div>
  )
}
