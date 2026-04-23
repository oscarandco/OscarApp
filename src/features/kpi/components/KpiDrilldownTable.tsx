import { useState } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import type {
  KpiDrilldownRow,
  KpiSnapshotScope,
} from '@/features/kpi/data/kpiApi'
import { useKpiDrilldown } from '@/features/kpi/hooks/useKpiDrilldown'
import {
  drilldownColumnsFor,
  formatRawNumber,
  metaFor,
  type KpiDrilldownColumns,
} from '@/features/kpi/kpiLabels'
import { formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'

type Props = {
  kpiCode: string
  periodStart: string
  scope: KpiSnapshotScope
  locationId: string | null
  staffMemberId: string | null
  enabled: boolean
}

/**
 * Raw-data diagnostic table for the currently-selected KPI. Renders
 * the generic 10-column shape returned by
 * `public.get_kpi_drilldown_live`, with a per-row toggle exposing the
 * `raw_payload` JSON for inspection.
 *
 * Mobile-safe: the table wrapper scrolls horizontally on narrow
 * screens so the columns do not crush each other. No per-KPI
 * rendering branches — every KPI comes through the same shape.
 */
export function KpiDrilldownTable(props: Props) {
  const {
    kpiCode,
    periodStart,
    scope,
    locationId,
    staffMemberId,
    enabled,
  } = props
  const meta = metaFor(kpiCode)
  const columns = drilldownColumnsFor(kpiCode)

  const { data, isLoading, isError, error, refetch } = useKpiDrilldown({
    kpiCode,
    periodStart,
    scope,
    locationId,
    staffMemberId,
    enabled,
  })

  return (
    <section
      className="mt-5 rounded-lg border border-slate-200 bg-white p-5 shadow-sm"
      data-testid="kpi-drilldown-panel"
    >
      <header className="mb-3 flex flex-col gap-1 sm:flex-row sm:items-baseline sm:justify-between">
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">
            Underlying rows
          </p>
          <h3 className="mt-0.5 text-base font-semibold text-slate-900">
            {meta.label}
          </h3>
        </div>
        {data ? (
          <p className="text-xs text-slate-500">
            {data.length.toLocaleString()} row{data.length === 1 ? '' : 's'}
          </p>
        ) : null}
      </header>

      <TableBody
        isLoading={isLoading}
        isError={isError}
        error={error}
        refetch={refetch}
        data={data}
        columns={columns}
      />
    </section>
  )
}

function TableBody(props: {
  isLoading: boolean
  isError: boolean
  error: unknown
  refetch: () => void
  data: KpiDrilldownRow[] | undefined
  columns: KpiDrilldownColumns
}) {
  const { isLoading, isError, error, refetch, data, columns } = props

  if (isLoading) {
    return <LoadingState testId="kpi-drilldown-loading" />
  }
  if (isError) {
    const detail = queryErrorDetail(error)
    return (
      <ErrorState
        title="Could not load drilldown"
        message={detail.message}
        error={detail.err}
        onRetry={() => refetch()}
        testId="kpi-drilldown-error"
      />
    )
  }
  const rows = data ?? []
  if (rows.length === 0) {
    return (
      <EmptyState
        title="No underlying rows"
        description="No rows were returned for the current KPI and filter combination."
        testId="kpi-drilldown-empty"
      />
    )
  }
  return <Table rows={rows} columns={columns} />
}

function Table({
  rows,
  columns,
}: {
  rows: KpiDrilldownRow[]
  columns: KpiDrilldownColumns
}) {
  const [expanded, setExpanded] = useState<Set<number>>(() => new Set())

  const toggle = (idx: number) => {
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(idx)) next.delete(idx)
      else next.add(idx)
      return next
    })
  }

  return (
    <div className="-mx-5 overflow-x-auto sm:mx-0">
      <table className="w-full min-w-[720px] text-left text-sm">
        <thead className="border-b border-slate-200 text-[11px] uppercase tracking-wide text-slate-500">
          <tr>
            <th scope="col" className="px-3 py-2 font-semibold">
              Type
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              {columns.primary}
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              {columns.secondary}
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              {columns.metric1}
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              {columns.metric2}
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Date
            </th>
            <th scope="col" className="px-3 py-2 font-semibold" aria-label="Raw details" />
          </tr>
        </thead>
        <tbody>
          {rows.map((row, idx) => {
            const isOpen = expanded.has(idx)
            return (
              <RowFragment
                key={idx}
                row={row}
                idx={idx}
                isOpen={isOpen}
                onToggle={toggle}
              />
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function RowFragment(props: {
  row: KpiDrilldownRow
  idx: number
  isOpen: boolean
  onToggle: (idx: number) => void
}) {
  const { row, idx, isOpen, onToggle } = props
  const hasPayload = row.raw_payload != null

  return (
    <>
      <tr className="border-b border-slate-100 align-top">
        <td className="px-3 py-2 text-xs font-medium text-slate-700">
          {row.row_type || '—'}
        </td>
        <td className="px-3 py-2 text-slate-900">
          {row.primary_label?.trim() || '—'}
        </td>
        <td className="px-3 py-2 text-slate-700">
          {row.secondary_label?.trim() || '—'}
        </td>
        <td className="px-3 py-2 text-right tabular-nums text-slate-800">
          {formatRawNumber(row.metric_value)}
        </td>
        <td className="px-3 py-2 text-right tabular-nums text-slate-800">
          {formatRawNumber(row.metric_value_2)}
        </td>
        <td className="px-3 py-2 text-slate-700">
          {formatShortDate(row.event_date)}
        </td>
        <td className="px-3 py-2 text-right">
          {hasPayload ? (
            <button
              type="button"
              onClick={() => onToggle(idx)}
              aria-expanded={isOpen}
              className="text-xs font-medium text-violet-700 hover:text-violet-900 focus:outline-none focus-visible:underline"
            >
              {isOpen ? 'Hide' : 'View'}
            </button>
          ) : null}
        </td>
      </tr>
      {isOpen && hasPayload ? (
        <tr className="border-b border-slate-100 bg-slate-50">
          <td colSpan={7} className="px-3 py-2">
            <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words text-[11px] leading-snug text-slate-700">
              {JSON.stringify(row.raw_payload, null, 2)}
            </pre>
          </td>
        </tr>
      ) : null}
    </>
  )
}
