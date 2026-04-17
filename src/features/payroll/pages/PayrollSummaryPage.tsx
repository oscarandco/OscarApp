import { useMemo, useState } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { SummaryFiltersBar } from '@/features/payroll/components/SummaryFiltersBar'
import { WeeklySummaryStats } from '@/features/payroll/components/WeeklySummaryStats'
import { WeeklySummaryTable } from '@/features/payroll/components/WeeklySummaryTable'
import { useMyWeeklyCommissionSummary } from '@/features/payroll/hooks/useMyWeeklyCommissionSummary'
import { aggregateWeeklyCommissionSummaryByStaffWeek } from '@/lib/aggregateWeeklyCommissionSummaryByStaffWeek'
import {
  filterStylistSummaryRows,
  uniqueLocationOptions,
  uniquePayWeekStartOptions,
} from '@/lib/payrollSummaryFilters'
import { queryErrorDetail } from '@/lib/queryError'
import { sortSummaryRowsNewestFirst } from '@/lib/payrollSorting'

export function PayrollSummaryPage() {
  const { data, isLoading, isError, error, refetch } =
    useMyWeeklyCommissionSummary()

  const [locationId, setLocationId] = useState('')
  const [payWeekStart, setPayWeekStart] = useState('')
  const [search, setSearch] = useState('')
  const [splitByLocation, setSplitByLocation] = useState(false)

  const sourceRows = useMemo(() => {
    const raw = data ?? []
    return sortSummaryRowsNewestFirst(raw)
  }, [data])

  const locationOptions = useMemo(
    () => uniqueLocationOptions(sourceRows),
    [sourceRows],
  )

  const weekBeginningOptions = useMemo(
    () => uniquePayWeekStartOptions(sourceRows),
    [sourceRows],
  )

  const filteredRows = useMemo(
    () =>
      filterStylistSummaryRows(sourceRows, {
        locationId,
        search,
        payWeekStart,
      }),
    [sourceRows, locationId, search, payWeekStart],
  )

  const displayRows = useMemo(() => {
    if (splitByLocation) return filteredRows
    return aggregateWeeklyCommissionSummaryByStaffWeek(filteredRows)
  }, [filteredRows, splitByLocation])

  const hasFilters = Boolean(locationId || payWeekStart || search.trim())
  const showReset = hasFilters

  function resetFilters() {
    setLocationId('')
    setPayWeekStart('')
    setSearch('')
  }

  if (isLoading) {
    return (
      <div data-testid="payroll-summary-page">
        <LoadingState
          message="Loading weekly commission…"
          testId="payroll-summary-loading"
        />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="payroll-summary-page">
        <ErrorState
          title="Could not load weekly summary"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="payroll-summary-error"
        />
      </div>
    )
  }

  return (
    <div data-testid="payroll-summary-page">
      <PageHeader
        title="Weekly payroll"
        description="Pay weeks run Monday–Sunday. Commission is finalized after Sunday; pay is the following Thursday. By default, rows combine commission across locations for each pay week; use Summary rows to split by site. Filter to narrow the list."
      />
      {sourceRows.length === 0 ? (
        <EmptyState
          title="No commission or payroll rows found"
          description="The reporting service returned no summary lines for your account. If you expect payroll here, confirm your access is active or try again after data is posted."
          testId="payroll-summary-empty"
        />
      ) : (
        <>
          <SummaryFiltersBar
            variant="stylist"
            locationId={locationId}
            onLocationId={setLocationId}
            locationOptions={locationOptions}
            weekBeginningFilter={payWeekStart}
            onWeekBeginningFilter={setPayWeekStart}
            weekBeginningOptions={weekBeginningOptions}
            search={search}
            onSearch={setSearch}
            searchPlaceholder="Search by display name…"
            onReset={resetFilters}
            showReset={showReset}
            splitByLocation={splitByLocation}
            onSplitByLocationChange={setSplitByLocation}
          />
          {hasFilters ? (
            <p
              className="mb-4 text-xs text-slate-500"
              data-testid="payroll-summary-diagnostics"
            >
              Showing {displayRows.length} of {filteredRows.length} row
              {filteredRows.length === 1 ? '' : 's'} (filters on).
            </p>
          ) : splitByLocation ? (
            <p
              className="mb-4 text-xs text-slate-500"
              data-testid="payroll-summary-diagnostics"
            >
              Showing {sourceRows.length} row
              {sourceRows.length === 1 ? '' : 's'} from the server (newest pay
              week first).
            </p>
          ) : (
            <p
              className="mb-4 text-xs text-slate-500"
              data-testid="payroll-summary-diagnostics"
            >
              Showing {displayRows.length} row
              {displayRows.length === 1 ? '' : 's'} (one per pay week, commission
              combined across locations; newest week first).
            </p>
          )}
          {filteredRows.length === 0 ? (
            <EmptyState
              title="No rows match your filters"
              description="Clear filters or adjust location and search to see summary rows."
              testId="payroll-summary-filtered-empty"
            />
          ) : (
            <>
              <WeeklySummaryStats rows={displayRows} />
              <div className="mt-4">
                <WeeklySummaryTable rows={displayRows} />
              </div>
            </>
          )}
        </>
      )}
    </div>
  )
}
