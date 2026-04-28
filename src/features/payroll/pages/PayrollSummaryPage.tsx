import { useMemo, useState } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useAccessProfile } from '@/features/access/accessContext'
import { resolveRole } from '@/features/access/pageAccess'
import { SummaryFiltersBar } from '@/features/payroll/components/SummaryFiltersBar'
import {
  WeeklySummaryStats,
  type WeeklySummaryExtraTile,
} from '@/features/payroll/components/WeeklySummaryStats'
import { WeeklySummaryTable } from '@/features/payroll/components/WeeklySummaryTable'
import { useMyWeeklyCommissionSummary } from '@/features/payroll/hooks/useMyWeeklyCommissionSummary'
import { useSalesDailySheetsDataSources } from '@/features/payroll/hooks/useSalesDailySheetsDataSources'
import { mySalesVisibilityForRole } from '@/features/payroll/payrollSummaryPageVisibility'
import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { aggregateWeeklyCommissionSummaryByStaffWeek } from '@/lib/aggregateWeeklyCommissionSummaryByStaffWeek'
import { formatDateLabel } from '@/lib/formatters'
import {
  filterStylistSummaryRows,
  uniqueLocationOptions,
  uniquePayWeekStartOptions,
} from '@/lib/payrollSummaryFilters'
import { queryErrorDetail } from '@/lib/queryError'
import { sortSummaryRowsNewestFirst } from '@/lib/payrollSorting'

/**
 * ISO `YYYY-MM-DD` for the earliest available pay-week start across the
 * loaded summary rows, and for the latest pay-week start. Both are
 * `null` when the rows array is empty / has no parseable dates.
 */
function computeDateExtents(rows: WeeklyCommissionSummaryRow[]): {
  min: string | null
  max: string | null
} {
  let min: string | null = null
  let max: string | null = null
  for (const r of rows) {
    const w = r.pay_week_start ? String(r.pay_week_start).trim() : ''
    if (!w) continue
    if (min == null || w < min) min = w
    if (max == null || w > max) max = w
  }
  return { min, max }
}

/**
 * Default `dateFrom` = exactly one year before `dateMax` clamped up to
 * `dateMin` so we never serve a placeholder before the first available
 * data point. Returns `''` if no max is known.
 */
function defaultDateFromForRange(
  min: string | null,
  max: string | null,
): string {
  if (!max) return ''
  const m = new Date(`${max}T00:00:00Z`)
  if (Number.isNaN(m.getTime())) return min ?? ''
  m.setUTCFullYear(m.getUTCFullYear() - 1)
  let candidate = m.toISOString().slice(0, 10)
  if (min && candidate < min) candidate = min
  return candidate
}

export function PayrollSummaryPage() {
  const { data, isLoading, isError, error, refetch } =
    useMyWeeklyCommissionSummary()
  const { data: dataSources } = useSalesDailySheetsDataSources()

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

  // Date range filter — defaults to "exactly the latest 1 year of
  // available data" derived from the loaded rows. User edits drop into
  // override state so they persist across re-renders; clearing both
  // overrides via the Reset button restores the 1-year default.
  const [dateFromOverride, setDateFromOverride] = useState<string | null>(
    null,
  )
  const [dateToOverride, setDateToOverride] = useState<string | null>(null)

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

  // Earliest / latest pay-week start across the loaded summary rows.
  // Drives both the date-range input bounds (so the picker can extend
  // back to the first available row) and the default 1-year window.
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

  // Date-range scope is applied BEFORE the existing client-side
  // filters. Per-location sales tiles read from this set so they
  // respect the date range without being narrowed by Location / Week /
  // Search filters (per requirements).
  const dateScopedRows = useMemo(() => {
    if (!dateFrom && !dateTo) return sourceRows
    return sourceRows.filter((r) => {
      const w = r.pay_week_start ? String(r.pay_week_start).trim() : ''
      if (!w) return true
      if (dateFrom && w < dateFrom) return false
      if (dateTo && w > dateTo) return false
      return true
    })
  }, [sourceRows, dateFrom, dateTo])

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

  // Per-location SALES (EX GST) tiles for My Sales. One tile per data
  // source (typically TAKAPUNA + OREWA). Totals come from the
  // date-scoped rows so they reflect the date range only — Location /
  // Week / Search filters do not narrow them. Hidden completely if the
  // data sources RPC returned nothing.
  const perLocationSalesTiles = useMemo<WeeklySummaryExtraTile[]>(() => {
    const sources = dataSources ?? []
    if (sources.length === 0) return []
    const sumByLocationId = new Map<string, number>()
    let foundAny = false
    for (const r of dateScopedRows) {
      const id = r.location_id ? String(r.location_id).trim() : ''
      if (!id) continue
      const v = r.total_sales_ex_gst
      if (v == null || v === '') continue
      const n = typeof v === 'number' ? v : Number(v)
      if (!Number.isFinite(n)) continue
      sumByLocationId.set(id, (sumByLocationId.get(id) ?? 0) + n)
      foundAny = true
    }
    return sources
      .filter((s) => s.location_id && String(s.location_id).trim() !== '')
      .map((s) => {
        const id = String(s.location_id).trim()
        const labelLocation =
          s.location_name && String(s.location_name).trim() !== ''
            ? String(s.location_name).trim().toUpperCase()
            : (s.location_code ?? id).toUpperCase()
        return {
          key: `sales-ex-gst-${id}`,
          label: `Sales (ex GST) - ${labelLocation}`,
          value: foundAny ? sumByLocationId.get(id) ?? 0 : null,
        }
      })
  }, [dataSources, dateScopedRows])

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
            dateFrom={dateFrom}
            dateTo={dateTo}
            onDateFromChange={(v) => setDateFromOverride(v)}
            onDateToChange={(v) => setDateToOverride(v)}
            dateMin={dateExtents.min ?? undefined}
            dateMax={dateExtents.max ?? undefined}
          />
          {(dataSources ?? []).length > 0 ? (
            <ul
              className="mb-4 space-y-1 text-xs text-slate-600"
              data-testid="payroll-summary-data-sources"
            >
              {(dataSources ?? []).map((src, idx) => {
                const name =
                  (src.source_file_name &&
                    String(src.source_file_name).trim()) ||
                  'Unknown source file'
                const rowCount =
                  src.row_count == null ? 0 : Number(src.row_count)
                const first = formatDateLabel(src.first_sale_date ?? null)
                const last = formatDateLabel(src.last_sale_date ?? null)
                return (
                  <li
                    key={src.batch_id ?? `${name}-${idx}`}
                    data-testid={`payroll-summary-data-source-${idx + 1}`}
                  >
                    <span className="font-medium text-slate-700">
                      Data source {idx + 1}:
                    </span>{' '}
                    {name} —{' '}
                    {Number.isFinite(rowCount)
                      ? rowCount.toLocaleString()
                      : '0'}{' '}
                    rows, first row {first}, last row {last}
                  </li>
                )
              })}
            </ul>
          ) : null}
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
                showRowsShownCard={visibility.showRowsShownCard}
                extraTiles={perLocationSalesTiles}
              />
              <div className="mt-4">
                <WeeklySummaryTable
                  rows={displayRows}
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
        </>
      )}
    </div>
  )
}
