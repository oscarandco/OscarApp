import { useMemo, useState } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useAccessProfile } from '@/features/access/accessContext'
import { resolveRole } from '@/features/access/pageAccess'
import { SummaryFiltersBar } from '@/features/payroll/components/SummaryFiltersBar'
import { WeeklySummaryDataSourceLines } from '@/features/payroll/components/WeeklySummaryDataSourceLines'
import { WeeklySummaryDateRangeInputs } from '@/features/payroll/components/WeeklySummaryDateRangeInputs'
import { WeeklySummaryStats } from '@/features/payroll/components/WeeklySummaryStats'
import { WeeklySummaryTable } from '@/features/payroll/components/WeeklySummaryTable'
import { useMyWeeklyCommissionSummary } from '@/features/payroll/hooks/useMyWeeklyCommissionSummary'
import { useSalesDailySheetsDataSources } from '@/features/payroll/hooks/useSalesDailySheetsDataSources'
import { mySalesVisibilityForRole } from '@/features/payroll/payrollSummaryPageVisibility'
import { aggregateWeeklyCommissionSummaryByStaffWeek } from '@/lib/aggregateWeeklyCommissionSummaryByStaffWeek'
import {
  filterStylistSummaryRows,
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

export function PayrollSummaryPage() {
  const { data, isLoading, isError, error, refetch } =
    useMyWeeklyCommissionSummary()
  const { data: dataSources } = useSalesDailySheetsDataSources()

  const { normalized } = useAccessProfile()
  const role = useMemo(() => resolveRole(normalized), [normalized])
  const visibility = useMemo(() => mySalesVisibilityForRole(role), [role])

  const [locationId, setLocationId] = useState('')
  const [payWeekStart, setPayWeekStart] = useState('')
  const [search, setSearch] = useState('')
  const [splitByLocation, setSplitByLocation] = useState(false)

  const [dateFromOverride, setDateFromOverride] = useState<string | null>(
    null,
  )
  const [dateToOverride, setDateToOverride] = useState<string | null>(null)

  const forceHiddenColumnIds = useMemo(() => {
    const next = new Set(visibility.hiddenTableColumnIds)
    if (!splitByLocation) next.add('location')
    return next
  }, [visibility.hiddenTableColumnIds, splitByLocation])

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
      filterStylistSummaryRows(dateScopedRows, {
        locationId,
        search,
        payWeekStart,
      }),
    [dateScopedRows, locationId, search, payWeekStart],
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
  const hasFilters =
    Boolean(locationId || payWeekStart || search.trim()) || dateRangeChanged
  const showReset = hasFilters

  function resetFilters() {
    setLocationId('')
    setPayWeekStart('')
    setSearch('')
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
        dateFromTestId="payroll-summary-toolbar-date-from"
        dateToTestId="payroll-summary-toolbar-date-to"
      />
      <WeeklySummaryDataSourceLines
        sources={dataSources}
        listTestId="payroll-summary-data-sources"
        lineTestIdPrefix="payroll-summary-data-source"
        variant="toolbar"
      />
    </>
  )

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
          <WeeklySummaryStats
            rows={displayRows}
            weeksCardLabel="Number of weeks shown"
            commissionCardLabel="Commission"
            showCommissionCard={visibility.showCommissionCard}
            showSalesCard={visibility.showSalesCard}
            showRowsShownCard={visibility.showRowsShownCard}
            extraTiles={perLocationSalesTiles}
          />
          <div className="mt-4">
            <WeeklySummaryTable
              rows={displayRows}
              tableStructureSample={sourceRows[0] ?? null}
              emptyBodyMessage={
                displayRows.length === 0
                  ? 'No rows match your filters.'
                  : undefined
              }
              toolbarBeforeColumns={tableToolbar}
              forceHiddenColumnIds={forceHiddenColumnIds}
              showColumnPicker={visibility.showColumnPicker}
              columnLabelOverrides={visibility.columnLabelOverrides}
              mobileHiddenColumnIds={visibility.mobileHiddenColumnIds}
              mobileColumnLabelOverrides={
                visibility.mobileColumnLabelOverrides
              }
              mobileDetailLabel={visibility.mobileDetailLabel}
            />
          </div>
        </>
      )}
    </div>
  )
}
