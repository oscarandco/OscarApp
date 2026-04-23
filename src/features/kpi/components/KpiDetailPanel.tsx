import type { KpiSnapshotRow } from '@/features/kpi/data/kpiApi'
import {
  formatKpiValue,
  formatRawNumber,
  metaFor,
} from '@/features/kpi/kpiLabels'
import { formatShortDate } from '@/lib/formatters'

/**
 * Diagnostic detail panel for the currently-selected KPI tile.
 *
 * Reads only from the in-memory snapshot row — no new RPC, no new
 * math. Values shown are exactly what the snapshot dispatcher
 * returned for the selected `(period, scope)` tuple, plus the
 * pre-formatted headline value so the panel agrees with the card.
 *
 * Mobile-safe: the field list stacks to one column below `sm`.
 */
export function KpiDetailPanel({ row }: { row: KpiSnapshotRow }) {
  const meta = metaFor(row.kpi_code)

  return (
    <section
      className="rounded-lg border border-slate-200 bg-white p-5 shadow-sm lg:sticky lg:top-4"
      data-testid="kpi-detail-panel"
    >
      <header className="mb-4">
        <p className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">
          Selected KPI
        </p>
        <h2 className="mt-1 text-lg font-semibold text-slate-900">
          {meta.label}
        </h2>
        {meta.description ? (
          <p className="mt-1 text-sm text-slate-600">{meta.description}</p>
        ) : null}
      </header>

      <dl className="grid grid-cols-1 gap-x-6 gap-y-2 sm:grid-cols-2 lg:grid-cols-1">
        <Field label="Value" value={formatKpiValue(meta.format, row.value)} />
        <Field label="Numerator" value={formatRawNumber(row.value_numerator)} />
        <Field
          label="Denominator"
          value={formatRawNumber(row.value_denominator)}
        />
        <Field label="Scope" value={formatScope(row.scope_type)} />
        <Field label="Period start" value={formatShortDate(row.period_start)} />
        <Field label="Period end" value={formatShortDate(row.period_end)} />
        <Field label="MTD through" value={formatShortDate(row.mtd_through)} />
        {row.location_id ? (
          <Field label="Location ID" value={row.location_id} mono />
        ) : null}
        {row.staff_member_id ? (
          <Field label="Staff member ID" value={row.staff_member_id} mono />
        ) : null}
        <Field
          label="Source"
          value={row.source ?? '—'}
          wrap
          className="sm:col-span-2 lg:col-span-1"
        />
      </dl>
    </section>
  )
}

function Field({
  label,
  value,
  mono = false,
  wrap = false,
  className,
}: {
  label: string
  value: string
  mono?: boolean
  wrap?: boolean
  className?: string
}) {
  const valueClasses = [
    'text-sm text-slate-800',
    mono ? 'font-mono text-xs text-slate-700' : '',
    wrap ? 'break-words' : 'truncate',
  ]
    .filter(Boolean)
    .join(' ')

  return (
    <div className={className}>
      <dt className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">
        {label}
      </dt>
      <dd className={`mt-0.5 ${valueClasses}`}>{value}</dd>
    </div>
  )
}

function formatScope(scope: KpiSnapshotRow['scope_type']): string {
  switch (scope) {
    case 'business':
      return 'Business'
    case 'location':
      return 'Location'
    case 'staff':
      return 'Staff'
    default:
      return String(scope)
  }
}
