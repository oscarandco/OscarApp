import { useMemo, useState } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { AdminSummaryTable } from '@/features/admin/components/AdminSummaryTable'
import { useAdminPayrollSummaryWeekly } from '@/features/admin/hooks/useAdminPayrollSummaryWeekly'
import { SummaryFiltersBar } from '@/features/payroll/components/SummaryFiltersBar'
import { WeeklySummaryStats } from '@/features/payroll/components/WeeklySummaryStats'
import {
  filterAdminSummaryRows,
  uniqueLocationOptions,
} from '@/lib/payrollSummaryFilters'
import { queryErrorDetail } from '@/lib/queryError'
import { sortSummaryRowsNewestFirst } from '@/lib/payrollSorting'

export function AdminPayrollSummaryPage() {
  const { data, isLoading, isError, error, refetch } =
    useAdminPayrollSummaryWeekly()

  const [locationId, setLocationId] = useState('')
  const [search, setSearch] = useState('')

  const sourceRows = useMemo(() => {
    const raw = data ?? []
    return sortSummaryRowsNewestFirst(raw)
  }, [data])

  const locationOptions = useMemo(
    () => uniqueLocationOptions(sourceRows),
    [sourceRows],
  )

  const filteredRows = useMemo(
    () => filterAdminSummaryRows(sourceRows, { locationId, search }),
    [sourceRows, locationId, search],
  )

  const hasFilters = Boolean(locationId || search.trim())
  const showReset = hasFilters

  function resetFilters() {
    setLocationId('')
    setSearch('')
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
    <div data-testid="admin-summary-page" className="max-w-[100vw]">
      <PageHeader
        title="Admin — weekly payroll"
        description="All-scope weekly summary (server permission checks apply). Newest pay weeks first; each row is one split from the reporting function. Filter by location or staff name below."
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
            search={search}
            onSearch={setSearch}
            searchPlaceholder="Search staff name…"
            onReset={resetFilters}
            showReset={showReset}
          />
          {hasFilters ? (
            <p
              className="mb-4 text-xs text-slate-500"
              data-testid="admin-summary-diagnostics"
            >
              Showing {filteredRows.length} of {sourceRows.length} row
              {sourceRows.length === 1 ? '' : 's'} (filters on).
            </p>
          ) : (
            <p
              className="mb-4 text-xs text-slate-500"
              data-testid="admin-summary-diagnostics"
            >
              Showing {sourceRows.length} row
              {sourceRows.length === 1 ? '' : 's'} from the admin reporting
              function.
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
              <WeeklySummaryStats rows={filteredRows} />
              <div className="mt-4">
                <AdminSummaryTable rows={filteredRows} />
              </div>
            </>
          )}
        </>
      )}
    </div>
  )
}
