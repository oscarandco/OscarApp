import { useMemo, useState } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { AdminSummaryTable } from '@/features/admin/components/AdminSummaryTable'
import { useAdminPayrollSummaryWeekly } from '@/features/admin/hooks/useAdminPayrollSummaryWeekly'
import { SummaryFiltersBar } from '@/features/payroll/components/SummaryFiltersBar'
import { WeeklySummaryDataSourceLines } from '@/features/payroll/components/WeeklySummaryDataSourceLines'
import { WeeklySummaryDateRangeInputs } from '@/features/payroll/components/WeeklySummaryDateRangeInputs'
import { WeeklySummaryStats } from '@/features/payroll/components/WeeklySummaryStats'
import { useSalesDailySheetsDataSources } from '@/features/payroll/hooks/useSalesDailySheetsDataSources'
import { aggregateWeeklyCommissionSummaryByStaffWeek } from '@/lib/aggregateWeeklyCommissionSummaryByStaffWeek'
import {
  filterAdminSummaryRows,
  uniqueLocationOptions,
  uniquePayWeekStartOptions,
} from '@/lib/payrollSummaryFilters'
import { queryErrorDetail } from '@/lib/queryError'
import { sortSummaryRowsNewestFirst } from '@/lib/payrollSorting'
import {
  buildPerLocationSalesExtraTiles,
  computeDateExtents,
  defaultDateFromForRange,
  filterRowsByPayWeekDateRange,
} from '@/lib/weeklySummaryReporting'

export function AdminPayrollSummaryPage() {
  const { data, isLoading, isError, error, refetch } =
    useAdminPayrollSummaryWeekly()
  const { data: dataSources } = useSalesDailySheetsDataSources()

  const [locationId, setLocationId] = useState('')
  const [payWeekStart, setPayWeekStart] = useState('')
  const [search, setSearch] = useState('')
  const [unconfiguredOnly, setUnconfiguredOnly] = useState(false)
  const [splitByLocation, setSplitByLocation] = useState(false)

  const [dateFromOverride, setDateFromOverride] = useState<string | null>(
    null,
  )
  const [dateToOverride, setDateToOverride] = useState<string | null>(null)

  const sourceRows = useMemo(() => {
    const raw = data ?? []
    return sortSummaryRowsNewestFirst(raw)
  }, [data])

  const dateExtents = useMemo(() => computeDateExtents(sourceRows), [
    sourceRows,
  ])

  const defaultDateFrom = useMemo(
    () => defaultDateFromForRange(dateExtents.min, dateExtents.max),
    [dateExtents.min, dateExtents.max],
  )
  const defaultDateTo = dateExtents.max ?? ''

  const dateFrom = dateFromOverride ?? defaultDateFrom
  const dateTo = dateToOverride ?? defaultDateTo

  const dateScopedRows = useMemo(
    () => filterRowsByPayWeekDateRange(sourceRows, dateFrom, dateTo),
    [sourceRows, dateFrom, dateTo],
  )

  const locationOptions = useMemo(
    () => uniqueLocationOptions(dateScopedRows),
    [dateScopedRows],
  )

  const weekBeginningOptions = useMemo(
    () => uniquePayWeekStartOptions(dateScopedRows),
    [dateScopedRows],
  )

  const filteredRows = useMemo(
    () =>
      filterAdminSummaryRows(dateScopedRows, {
        locationId,
        search,
        payWeekStart,
        unconfiguredPaidStaffOnly: unconfiguredOnly,
      }),
    [dateScopedRows, locationId, search, payWeekStart, unconfiguredOnly],
  )

  const displayRows = useMemo(() => {
    if (splitByLocation) return filteredRows
    return aggregateWeeklyCommissionSummaryByStaffWeek(filteredRows)
  }, [filteredRows, splitByLocation])

  const perLocationSalesTiles = useMemo(
    () => buildPerLocationSalesExtraTiles(dataSources, dateScopedRows),
    [dataSources, dateScopedRows],
  )

  const dateRangeChanged =
    dateFromOverride != null || dateToOverride != null
  const hasFilters = Boolean(
    locationId ||
      payWeekStart ||
      search.trim() ||
      unconfiguredOnly ||
      dateRangeChanged,
  )
  const showReset = hasFilters

  function resetFilters() {
    setLocationId('')
    setPayWeekStart('')
    setSearch('')
    setUnconfiguredOnly(false)
    setDateFromOverride(null)
    setDateToOverride(null)
  }

  const tableToolbar = (
    <>
      <WeeklySummaryDateRangeInputs
        dateFrom={dateFrom}
        dateTo={dateTo}
        onDateFromChange={(v) => setDateFromOverride(v)}
        onDateToChange={(v) => setDateToOverride(v)}
        dateMin={dateExtents.min ?? undefined}
        dateMax={dateExtents.max ?? undefined}
        dateFromTestId="admin-summary-toolbar-date-from"
        dateToTestId="admin-summary-toolbar-date-to"
      />
      <WeeklySummaryDataSourceLines
        sources={dataSources}
        listTestId="admin-summary-data-sources"
        lineTestIdPrefix="admin-summary-data-source"
        variant="toolbar"
      />
    </>
  )

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
        title="Sales summary"
        description="Pay weeks run Monday - Sunday. Commission is finalized after Sunday; pay is the following Thursday. 
        By default, rows combine sales and commission across locations for each pay week; use the Summary rows button to split by site. Filter to narrow the list."
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
          <WeeklySummaryStats
            rows={displayRows}
            weeksCardLabel="Number of weeks shown"
            unconfiguredFilterProps={{
              active: unconfiguredOnly,
              onToggle: () => setUnconfiguredOnly((v) => !v),
            }}
            showSalesCard={false}
            showRowsShownCard={false}
            extraTiles={perLocationSalesTiles}
          />
          <div className="mt-4">
            <AdminSummaryTable
              rows={displayRows}
              splitByLocation={splitByLocation}
              tableStructureSample={sourceRows[0] ?? null}
              emptyBodyMessage={
                displayRows.length === 0
                  ? 'No rows match your filters.'
                  : undefined
              }
              toolbarBeforeColumns={tableToolbar}
            />
          </div>
        </>
      )}
    </div>
  )
}
