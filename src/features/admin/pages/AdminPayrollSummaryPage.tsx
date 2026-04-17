import { useMemo, useState } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { AdminSummaryTable } from '@/features/admin/components/AdminSummaryTable'
import { useAdminPayrollSummaryWeekly } from '@/features/admin/hooks/useAdminPayrollSummaryWeekly'
import { aggregateWeeklyCommissionSummaryByStaffWeek } from '@/lib/aggregateWeeklyCommissionSummaryByStaffWeek'
import { SummaryFiltersBar } from '@/features/payroll/components/SummaryFiltersBar'
import { WeeklySummaryStats } from '@/features/payroll/components/WeeklySummaryStats'
import {
  filterAdminSummaryRows,
  uniqueLocationOptions,
  uniquePayWeekStartOptions,
} from '@/lib/payrollSummaryFilters'
import { queryErrorDetail } from '@/lib/queryError'
import { sortSummaryRowsNewestFirst } from '@/lib/payrollSorting'

export function AdminPayrollSummaryPage() {
  const { data, isLoading, isError, error, refetch } =
    useAdminPayrollSummaryWeekly()

  const [locationId, setLocationId] = useState('')
  const [payWeekStart, setPayWeekStart] = useState('')
  const [search, setSearch] = useState('')
  const [unconfiguredOnly, setUnconfiguredOnly] = useState(false)
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
      filterAdminSummaryRows(sourceRows, {
        locationId,
        search,
        payWeekStart,
        unconfiguredPaidStaffOnly: unconfiguredOnly,
      }),
    [sourceRows, locationId, search, payWeekStart, unconfiguredOnly],
  )

  const displayRows = useMemo(() => {
    if (splitByLocation) return filteredRows
    return aggregateWeeklyCommissionSummaryByStaffWeek(filteredRows)
  }, [filteredRows, splitByLocation])

  const hasFilters = Boolean(
    locationId || payWeekStart || search.trim() || unconfiguredOnly,
  )
  const showReset = hasFilters

  function resetFilters() {
    setLocationId('')
    setPayWeekStart('')
    setSearch('')
    setUnconfiguredOnly(false)
  }

  if (isLoading) {
    return (
      <div data-testid="admin-summary-page">
        <LoadingState
          message="Loading admin payroll summary…"
          testId="admin-summary-loading"
        />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="admin-summary-page">
        <ErrorState
          title="Could not load admin payroll summary"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="admin-summary-error"
        />
      </div>
    )
  }

  return (
    <div data-testid="admin-summary-page">
      <PageHeader
        title="Admin — weekly payroll"
        description="All-scope weekly summary (server permission checks apply). By default, rows combine commission across locations for each staff member and pay week; use Summary rows to split by site. Filter by location or staff name below."
      />
      {sourceRows.length === 0 ? (
        <EmptyState
          title="No admin payroll rows"
          description="The admin summary returned no lines. Confirm staff data exists for this period, or check with operations if the reporting job has run."
          testId="admin-summary-empty"
        />
      ) : (
        <>
          <SummaryFiltersBar
            variant="admin"
            locationId={locationId}
            onLocationId={setLocationId}
            locationOptions={locationOptions}
            weekBeginningFilter={payWeekStart}
            onWeekBeginningFilter={setPayWeekStart}
            weekBeginningOptions={weekBeginningOptions}
            search={search}
            onSearch={setSearch}
            searchPlaceholder="Search staff name…"
            onReset={resetFilters}
            showReset={showReset}
            splitByLocation={splitByLocation}
            onSplitByLocationChange={setSplitByLocation}
          />
          {hasFilters ? (
            <p
              className="mb-4 text-xs text-slate-500"
              data-testid="admin-summary-diagnostics"
            >
              Showing {displayRows.length} of {filteredRows.length} row
              {filteredRows.length === 1 ? '' : 's'} (filters on).
            </p>
          ) : splitByLocation ? (
            <p
              className="mb-4 text-xs text-slate-500"
              data-testid="admin-summary-diagnostics"
            >
              Showing {sourceRows.length} row
              {sourceRows.length === 1 ? '' : 's'} from the admin reporting
              function.
            </p>
          ) : (
            <p
              className="mb-4 text-xs text-slate-500"
              data-testid="admin-summary-diagnostics"
            >
              Showing {displayRows.length} row
              {displayRows.length === 1 ? '' : 's'} (one per staff member and pay
              week, commission combined across locations).
            </p>
          )}
          {filteredRows.length === 0 ? (
            <EmptyState
              title="No rows match your filters"
              description="Clear filters or adjust location and search to see admin summary rows."
              testId="admin-summary-filtered-empty"
            />
          ) : (
            <>
              <WeeklySummaryStats
                rows={displayRows}
                unconfiguredFilterProps={{
                  active: unconfiguredOnly,
                  onToggle: () => setUnconfiguredOnly((v) => !v),
                }}
              />
              <div className="mt-4">
                <AdminSummaryTable
                  rows={displayRows}
                  splitByLocation={splitByLocation}
                />
              </div>
            </>
          )}
        </>
      )}
    </div>
  )
}
