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
import {
  WeeklySummaryStats,
  type WeeklySummaryExtraTile,
} from '@/features/payroll/components/WeeklySummaryStats'
import { AdminSummaryTable } from '@/features/admin/components/AdminSummaryTable'
import { useLocationSalesSummaryForMySales } from '@/features/payroll/hooks/useLocationSalesSummaryForMySales'
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
  payWeekInclusiveEndForStart,
  payWeekStartIfRangeIsExactlyOnePayWeek,
  sumTotalSalesExGstFromRows,
} from '@/lib/weeklySummaryReporting'

export function PayrollSummaryPage() {
  const {
    data,
    isLoading: mySummaryLoading,
    isError: mySummaryError,
    error: mySummaryQueryError,
    refetch: refetchMySummary,
  } = useMyWeeklyCommissionSummary()
  const { data: dataSources } = useSalesDailySheetsDataSources()
  const {
    data: locationSalesKpiRows,
    isLoading: locationSalesKpisLoading,
    isError: locationSalesKpisError,
    error: locationSalesKpisQueryError,
    refetch: refetchLocationSalesKpis,
  } = useLocationSalesSummaryForMySales()

  const isLoading = mySummaryLoading || locationSalesKpisLoading
  const isError = mySummaryError || locationSalesKpisError
  const error = mySummaryQueryError ?? locationSalesKpisQueryError
  const refetch = () => {
    void refetchMySummary()
    void refetchLocationSalesKpis()
  }

  const { normalized } = useAccessProfile()
  const role = useMemo(() => resolveRole(normalized), [normalized])
  const visibility = useMemo(() => mySalesVisibilityForRole(role), [role])
  /** Display-only: reorder comma-separated `work_performed_by` so the session stylist is first. */
  const workPerformedBySelfMatchNames = useMemo((): readonly string[] | null => {
    if (!normalized) return null
    const names: string[] = []
    const d = normalized.staffDisplayName?.trim()
    const f = normalized.staffFullName?.trim()
    if (d) names.push(d)
    if (f && f !== d) names.push(f)
    return names.length > 0 ? names : null
  }, [normalized])
  /** Access Management role (`resolveRole`): only managers/admins see KPI sales tiles. */
  const canViewSalesSummaryCards = role === 'admin' || role === 'manager'

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
    () => filterRowsByPayWeekDateRange(sourceRows, resolvedDateFrom, resolvedDateTo),
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

  /** All-staff location totals (same basis as Sales Summary), then date/week/location filters for KPIs only. */
  const salesKpiBasisRows = useMemo(() => {
    const raw = locationSalesKpiRows ?? []
    let scoped = filterRowsByPayWeekDateRange(
      raw,
      resolvedDateFrom,
      resolvedDateTo,
    )
    if (locationId.trim()) {
      const lid = locationId.trim()
      scoped = scoped.filter(
        (r) => String(r.location_id ?? '').trim() === lid,
      )
    }
    return scoped
  }, [
    locationSalesKpiRows,
    resolvedDateFrom,
    resolvedDateTo,
    locationId,
  ])

  const perLocationSalesTiles = useMemo(
    () => buildPerLocationSalesExtraTiles(dataSources, salesKpiBasisRows),
    [dataSources, salesKpiBasisRows],
  )

  const salesExtraTiles = useMemo((): WeeklySummaryExtraTile[] => {
    const totalVal = sumTotalSalesExGstFromRows(salesKpiBasisRows)
    const totalTile: WeeklySummaryExtraTile = {
      key: 'total-sales-ex-gst',
      label: 'Total sales (ex GST)',
      value: totalVal,
    }
    return [totalTile, ...perLocationSalesTiles]
  }, [salesKpiBasisRows, perLocationSalesTiles])

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
      listTestId="payroll-summary-data-sources"
      lineTestIdPrefix="payroll-summary-data-source"
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
      dateFromTestId="payroll-summary-toolbar-date-from"
      dateToTestId="payroll-summary-toolbar-date-to"
    />
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
            onWeekBeginningFilter={handleWeekBeginningFilter}
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
            extraTiles={canViewSalesSummaryCards ? salesExtraTiles : undefined}
          />
          <div className="mt-4 w-full min-w-0">
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
              mySalesTableOptions={{
                forceHiddenColumnIds,
                showColumnPicker: visibility.showColumnPicker,
                workPerformedBySelfMatchNames,
              }}
            />
          </div>
        </>
      )}
    </div>
  )
}
