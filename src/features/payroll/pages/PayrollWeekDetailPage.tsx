import { useMemo, useState } from 'react'
import { useParams } from 'react-router-dom'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { PayrollLineStats } from '@/features/payroll/components/PayrollLineStats'
import { PayrollLineTableViewportFrame } from '@/features/payroll/components/PayrollLineTableViewportFrame'
import { PayrollWeekHeader } from '@/features/payroll/components/PayrollWeekHeader'
import { SummaryFiltersBar } from '@/features/payroll/components/SummaryFiltersBar'
import { useMyWeeklyCommissionLines } from '@/features/payroll/hooks/useMyWeeklyCommissionLines'
import { filterLineRows, uniqueLocationOptions } from '@/lib/payrollSummaryFilters'
import { formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'
import { parsePayWeekRouteParam } from '@/lib/routeParams'

export function PayrollWeekDetailPage() {
  const { payWeekStart: rawParam } = useParams<{ payWeekStart: string }>()
  const parsed = parsePayWeekRouteParam(rawParam)
  const payWeekForQuery = parsed.kind === 'ok' ? parsed.value : undefined

  const { data, isLoading, isError, error, refetch } =
    useMyWeeklyCommissionLines(payWeekForQuery)

  const [locationId, setLocationId] = useState('')
  const [search, setSearch] = useState('')

  const context = useMemo(() => {
    const lines = data ?? []
    const first = lines[0]
    return {
      payWeekEnd: first?.pay_week_end ?? null,
      payDate: first?.pay_date ?? null,
    }
  }, [data])

  const sourceRows = useMemo(() => data ?? [], [data])

  const locationOptions = useMemo(
    () => uniqueLocationOptions(sourceRows),
    [sourceRows],
  )

  const filteredRows = useMemo(
    () => filterLineRows(sourceRows, { locationId, search }),
    [sourceRows, locationId, search],
  )

  const hasFilters = Boolean(locationId || search.trim())
  const showReset = hasFilters

  function resetFilters() {
    setLocationId('')
    setSearch('')
  }

  if (parsed.kind === 'missing') {
    return (
      <div data-testid="payroll-detail-page" className="flex min-h-0 min-w-0 flex-1 flex-col">
        <ErrorState
          title="No pay week selected"
          message="Open this page from the weekly summary by choosing a pay week (View lines)."
          testId="payroll-detail-param-error"
        />
      </div>
    )
  }

  if (parsed.kind === 'invalid') {
    return (
      <div data-testid="payroll-detail-page" className="flex min-h-0 min-w-0 flex-1 flex-col">
        <ErrorState
          title="Invalid pay week link"
          message={`${parsed.reason} (Received: ${parsed.rawDisplay})`}
          testId="payroll-detail-param-error"
        />
      </div>
    )
  }

  const payWeekStart = parsed.value

  if (isLoading) {
    return (
      <div data-testid="payroll-detail-page" className="flex min-h-0 min-w-0 flex-1 flex-col">
        <PayrollWeekHeader payWeekStart={payWeekStart} />
        <LoadingState
          message="Loading commission lines…"
          testId="payroll-detail-loading"
        />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="payroll-detail-page" className="flex min-h-0 min-w-0 flex-1 flex-col">
        <PayrollWeekHeader payWeekStart={payWeekStart} />
        <ErrorState
          title="Could not load lines for this week"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="payroll-detail-error"
        />
      </div>
    )
  }

  const weekLabel = formatShortDate(payWeekStart)

  return (
    <div data-testid="payroll-detail-page" className="flex min-h-0 min-w-0 flex-1 flex-col">
      <div className="shrink-0">
        <PayrollWeekHeader
          payWeekStart={payWeekStart}
          payWeekEnd={context.payWeekEnd}
          payDate={context.payDate}
        />
        <PageHeader title="Line detail" />
      </div>
      {sourceRows.length === 0 ? (
        <EmptyState
          title="No lines for this pay week"
          description={`The reporting service returned no line items for week starting ${payWeekStart}. If sales should appear here, confirm the week is posted or contact your manager.`}
          testId="payroll-detail-empty"
        />
      ) : (
        <>
          <div className="shrink-0">
            <SummaryFiltersBar
              variant="stylist"
              locationId={locationId}
              onLocationId={setLocationId}
              locationOptions={locationOptions}
              search={search}
              onSearch={setSearch}
              searchPlaceholder="Search by staff, customer, invoice…"
              onReset={resetFilters}
              showReset={showReset}
            />
            {hasFilters ? (
              <p
                className="mb-4 text-xs text-slate-500"
                data-testid="payroll-detail-diagnostics"
              >
                Showing {filteredRows.length} of {sourceRows.length} line
                {sourceRows.length === 1 ? '' : 's'} (filters on).
              </p>
            ) : (
              <p
                className="mb-4 text-xs text-slate-500"
                data-testid="payroll-detail-diagnostics"
              >
                {sourceRows.length} line{sourceRows.length === 1 ? '' : 's'} for week
                starting <span className="font-mono text-slate-700">{payWeekStart}</span>
                {weekLabel !== '—' ? ` (${weekLabel})` : null}.
              </p>
            )}
          </div>
          {filteredRows.length === 0 ? (
            <EmptyState
              title="No rows match your filters"
              description="Clear filters or adjust location and search to see lines."
              testId="payroll-detail-filtered-empty"
            />
          ) : (
            <div className="mt-2 flex min-h-0 min-w-0 flex-1 flex-col gap-4">
              <div className="shrink-0">
                <PayrollLineStats rows={filteredRows} />
              </div>
              <PayrollLineTableViewportFrame rows={filteredRows} />
            </div>
          )}
        </>
      )}
    </div>
  )
}
