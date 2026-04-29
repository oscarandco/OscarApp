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
import { WeeklySummaryStats, type WeeklySummaryExtraTile } from '@/features/payroll/components/WeeklySummaryStats'
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
  payWeekInclusiveEndForStart,
  payWeekStartIfRangeIsExactlyOnePayWeek,
  sumTotalSalesExGstFromRows,
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

  const manualDateFrom = dateFromOverride ?? defaultDateFrom
  const manualDateTo = dateToOverride ?? defaultDateTo

  const payWeekTrim = payWeekStart.trim()
  const weekEndResolved = payWeekTrim
    ? payWeekInclusiveEndForStart(sourceRows, payWeekTrim) || payWeekTrim
    : ''

  const resolvedDateFrom = payWeekTrim ? payWeekTrim : manualDateFrom
  const resolvedDateTo = payWeekTrim ? weekEndResolved : manualDateTo

  const dateFrom = resolvedDateFrom
  const dateTo = resolvedDateTo

  const dateScopedRows = useMemo(
    () =>
      filterRowsByPayWeekDateRange(
        sourceRows,
        resolvedDateFrom,
        resolvedDateTo,
      ),
    [sourceRows, resolvedDateFrom, resolvedDateTo],
  )

  const rowsForWeekBeginningOptions = useMemo(() => {
    if (payWeekTrim) {
      return filterRowsByPayWeekDateRange(
        sourceRows,
        dateFromOverride ?? defaultDateFrom,
        dateToOverride ?? defaultDateTo,
      )
    }
    return dateScopedRows
  }, [
    payWeekTrim,
    sourceRows,
    dateFromOverride,
    dateToOverride,
    defaultDateFrom,
    defaultDateTo,
    dateScopedRows,
  ])

  const locationOptions = useMemo(
    () => uniqueLocationOptions(dateScopedRows),
    [dateScopedRows],
  )

  const weekBeginningOptions = useMemo(
    () => uniquePayWeekStartOptions(rowsForWeekBeginningOptions),
    [rowsForWeekBeginningOptions],
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

  const salesExtraTiles = useMemo((): WeeklySummaryExtraTile[] => {
    const totalVal = sumTotalSalesExGstFromRows(dateScopedRows)
    const totalTile: WeeklySummaryExtraTile = {
      key: 'total-sales-ex-gst',
      label: 'Total sales (ex GST)',
      value: totalVal,
    }
    return [totalTile, ...perLocationSalesTiles]
  }, [dateScopedRows, perLocationSalesTiles])

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

  function handleWeekBeginningFilter(next: string) {
    if (next.trim() === '') {
      setPayWeekStart('')
      setDateFromOverride(null)
      setDateToOverride(null)
    } else {
      setPayWeekStart(next)
      setDateFromOverride(null)
      setDateToOverride(null)
    }
  }

  function applyToolbarDateRange(nextFrom: string, nextTo: string) {
    const fromNorm =
      nextFrom.trim() !== '' ? nextFrom.trim() : defaultDateFrom
    const toNorm = nextTo.trim() !== '' ? nextTo.trim() : defaultDateTo
    const match = payWeekStartIfRangeIsExactlyOnePayWeek(
      sourceRows,
      fromNorm,
      toNorm,
    )
    if (match) {
      setPayWeekStart(match)
      setDateFromOverride(null)
      setDateToOverride(null)
    } else {
      setPayWeekStart('')
      setDateFromOverride(nextFrom.trim() !== '' ? nextFrom.trim() : null)
      setDateToOverride(nextTo.trim() !== '' ? nextTo.trim() : null)
    }
  }

  const toolbarDataSources = (
    <WeeklySummaryDataSourceLines
      sources={dataSources}
      listTestId="admin-summary-data-sources"
      lineTestIdPrefix="admin-summary-data-source"
      variant="toolbar"
    />
  )

  const toolbarDateRange = (
    <WeeklySummaryDateRangeInputs
      dateFrom={dateFrom}
      dateTo={dateTo}
      onDateFromChange={(v) =>
        applyToolbarDateRange(v, payWeekTrim ? weekEndResolved : manualDateTo)
      }
      onDateToChange={(v) =>
        applyToolbarDateRange(
          payWeekTrim ? payWeekTrim : manualDateFrom,
          v,
        )
      }
      dateMin={dateExtents.min ?? undefined}
      dateMax={dateExtents.max ?? undefined}
      dateFromTestId="admin-summary-toolbar-date-from"
      dateToTestId="admin-summary-toolbar-date-to"
    />
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
            onWeekBeginningFilter={handleWeekBeginningFilter}
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
            extraTiles={salesExtraTiles}
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
              toolbarDataSources={toolbarDataSources}
              toolbarDateRange={toolbarDateRange}
            />
          </div>
        </>
      )}
    </div>
  )
}
