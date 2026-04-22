import { useMemo } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { KpiCard } from '@/features/kpi/components/KpiCard'
import { useKpiSnapshot } from '@/features/kpi/hooks/useKpiSnapshot'
import { kpiSortComparator } from '@/features/kpi/kpiLabels'
import { formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'

/**
 * First UI slice for KPI reporting. Renders the live snapshot from
 * `public.get_kpi_snapshot_live` in a responsive card grid.
 *
 * Scope / period controls are intentionally omitted:
 *   • Period is fixed to the current month (backend default).
 *   • Scope follows the caller's default accessible scope — the
 *     backend's `private.kpi_resolve_scope` silently restricts
 *     stylist / assistant callers to their own staff scope and
 *     leaves manager / admin callers at business scope. No UI
 *     switching is exposed in this slice; see `KpiDashboardPage`
 *     deferral note for scope/period pickers.
 */
export function KpiDashboardPage() {
  const { data, isLoading, isError, error, refetch } = useKpiSnapshot()

  const sortedRows = useMemo(() => {
    const rows = data ?? []
    return [...rows].sort((a, b) => kpiSortComparator(a.kpi_code, b.kpi_code))
  }, [data])

  const first = sortedRows[0]
  const periodLabel = first
    ? first.is_current_open_month
      ? `Month-to-date · through ${formatShortDate(first.mtd_through)}`
      : `${formatShortDate(first.period_start)} – ${formatShortDate(first.period_end)}`
    : 'Current month'

  const scopeLabel = first
    ? first.scope_type === 'business'
      ? 'Business'
      : first.scope_type === 'location'
        ? 'Location'
        : 'Self'
    : null

  const description = scopeLabel
    ? `${scopeLabel} · ${periodLabel}`
    : periodLabel

  if (isLoading) {
    return (
      <>
        <PageHeader title="KPIs" description="Loading current month…" />
        <LoadingState testId="kpi-dashboard-loading" />
      </>
    )
  }

  if (isError) {
    const detail = queryErrorDetail(error)
    return (
      <>
        <PageHeader title="KPIs" />
        <ErrorState
          title="Could not load KPIs"
          message={detail.message}
          error={detail.err}
          onRetry={() => refetch()}
          testId="kpi-dashboard-error"
        />
      </>
    )
  }

  if (sortedRows.length === 0) {
    return (
      <>
        <PageHeader title="KPIs" description={description} />
        <EmptyState
          title="No KPIs available"
          description="No KPI rows were returned for the current month yet."
          testId="kpi-dashboard-empty"
        />
      </>
    )
  }

  return (
    <>
      <PageHeader title="KPIs" description={description} />
      <div
        className="grid grid-cols-1 gap-3 sm:grid-cols-2 md:grid-cols-3 xl:grid-cols-4"
        data-testid="kpi-dashboard-grid"
      >
        {sortedRows.map((row) => (
          <KpiCard key={row.kpi_code} row={row} />
        ))}
      </div>
    </>
  )
}
