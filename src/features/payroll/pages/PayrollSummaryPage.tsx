import { useMemo, useState } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useAccessProfile } from '@/features/access/accessContext'
import { resolveRole } from '@/features/access/pageAccess'
import { SummaryFiltersBar } from '@/features/payroll/components/SummaryFiltersBar'
import { WeeklySummaryStats } from '@/features/payroll/components/WeeklySummaryStats'
import { WeeklySummaryTable } from '@/features/payroll/components/WeeklySummaryTable'
import { useMyWeeklyCommissionSummary } from '@/features/payroll/hooks/useMyWeeklyCommissionSummary'
import { mySalesVisibilityForRole } from '@/features/payroll/payrollSummaryPageVisibility'
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

  // Resolve the user's role once and feed it through the centralised
  // My Sales visibility helper. Every role-based filter / card / column
  // decision below reads from `visibility` so the matrix lives in one
  // place — see `payrollSummaryPageVisibility.ts`.
  const { normalized } = useAccessProfile()
  const role = useMemo(() => resolveRole(normalized), [normalized])
  const visibility = useMemo(() => mySalesVisibilityForRole(role), [role])

  const [locationId, setLocationId] = useState('')
  const [payWeekStart, setPayWeekStart] = useState('')
  const [search, setSearch] = useState('')
  const [splitByLocation, setSplitByLocation] = useState(false)

  // Force-hidden table columns: role-driven hides from the visibility
  // helper, plus the filter-driven hide for `location` whenever the
  // Summary rows toggle is set to "Combined" (one row per staff +
  // week, regardless of site).
  const forceHiddenColumnIds = useMemo(() => {
    const next = new Set(visibility.hiddenTableColumnIds)
    if (!splitByLocation) next.add('location')
    return next
  }, [visibility.hiddenTableColumnIds, splitByLocation])

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
        title="My Sales"
        description="Pay weeks run Monday - Sunday. Commission is finalized after Sunday; pay is the following Thursday. 
        By default, rows combine sales and commission across locations for each pay week; use the Summary rows button to split by site. Filter to narrow the list."
      />
      {sourceRows.length === 0 ? (
        <EmptyState
          title="No sales or commission rows found"
          description="The reporting service returned no summary lines for your account. If you expect sales or commission data, confirm your access is active or try again after data is posted."
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
            showSearch={visibility.showSearchFilter}
            showLocation={visibility.showLocationFilter}
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
              <WeeklySummaryStats
                rows={displayRows}
                weeksCardLabel="Number of weeks shown"
                commissionCardLabel="Commission"
                showCommissionCard={visibility.showCommissionCard}
                showSalesCard={visibility.showSalesCard}
              />
              <div className="mt-4">
                <WeeklySummaryTable
                  rows={displayRows}
                  forceHiddenColumnIds={forceHiddenColumnIds}
                  showColumnPicker={visibility.showColumnPicker}
                />
              </div>
            </>
          )}
        </>
      )}
    </div>
  )
}
