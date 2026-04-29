import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { TableScrollArea } from '@/components/ui/TableScrollArea'
import { TableColumnSortHeader } from '@/components/ui/TableColumnSortHeader'
import { AdminPayrollLinesPreviewModal } from '@/features/admin/components/AdminPayrollLinesPreviewModal'
import { StaffLocationNavBadge } from '@/features/admin/components/StaffLocationNavBadge'
import { useAdminPayrollLinesWeekly } from '@/features/admin/hooks/useAdminPayrollLinesWeekly'
import { useAdminPayrollSummaryWeekly } from '@/features/admin/hooks/useAdminPayrollSummaryWeekly'
import {
  type DashboardCardFilter,
  aggregateTableAByStaff,
  aggregateTableBByStaff,
  aggregateWeekSummaryCards,
  filterLinesForDashboardCard,
} from '@/features/admin/utils/weeklyCommissionDashboardAggregates'
import { formatNzd } from '@/lib/formatters'
import { rpcListActiveLocationsForImport } from '@/lib/supabaseRpc'
import {
  filterAdminPayrollLinesForStaffWeek,
  uniquePayWeekStartOptions,
} from '@/lib/payrollSummaryFilters'
import { queryErrorDetail } from '@/lib/queryError'
import type { ColumnSortState } from '@/lib/tableSort'
import {
  sortWeeklyDashboardTableARows,
  sortWeeklyDashboardTableBRows,
} from '@/lib/weeklyDashboardTableSort'

/**
 * Weekly payroll dashboard summary tables only: smaller type, tighter rows,
 * stylist names on one line (horizontal scroll via TableScrollArea when needed).
 */
const dashTable = 'w-max min-w-full border-collapse text-xs'
const dashTh =
  'border-b border-slate-200 px-2 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-slate-600 sm:px-3 sm:py-2 sm:normal-case sm:text-xs sm:tracking-normal sm:text-slate-700'
const dashThRight = `${dashTh} text-right`
const dashThAction = `${dashTh} w-px`
const dashTdNum =
  'whitespace-nowrap border-b border-slate-100 px-2 py-1.5 tabular-nums text-slate-700 sm:px-3 sm:py-2'
const dashTdNumRight = `${dashTdNum} text-right`
const dashTdName =
  'whitespace-nowrap border-b border-slate-100 px-2 py-1.5 text-slate-700 sm:px-3 sm:py-2'
const dashTdText =
  'border-b border-slate-100 px-2 py-1.5 text-xs text-slate-700 sm:px-3 sm:py-2'
const dashTdAction =
  'whitespace-nowrap border-b border-slate-100 px-2 py-1.5 text-right align-middle text-slate-700 sm:px-3 sm:py-2'

const cardButtonBase =
  'w-full rounded-lg border px-4 py-3 text-left shadow-sm transition focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-2'
const cardButtonIdle =
  'border-slate-200 bg-white hover:border-violet-200 hover:bg-violet-50/50'
const cardButtonActive = 'border-violet-400 bg-violet-50 ring-2 ring-violet-300'

function sumColumn<T extends Record<string, unknown>>(rows: T[], key: keyof T): number {
  let t = 0
  for (const r of rows) {
    const v = r[key]
    const n = typeof v === 'number' ? v : Number(v)
    if (Number.isFinite(n)) t += n
  }
  return t
}

export function AdminWeeklyCommissionDashboardPage() {
  const summaryQuery = useAdminPayrollSummaryWeekly()
  const weekOptions = useMemo(
    () => uniquePayWeekStartOptions(summaryQuery.data ?? []),
    [summaryQuery.data],
  )

  const [selectedWeek, setSelectedWeek] = useState<string | null>(null)
  const [linePreview, setLinePreview] = useState<{
    staffLabel: string
    staffPaidId: string | null
  } | null>(null)
  const [cardFilter, setCardFilter] = useState<DashboardCardFilter | null>(null)
  const [tableASort, setTableASort] = useState<ColumnSortState>(null)
  const [tableBSort, setTableBSort] = useState<ColumnSortState>(null)

  useEffect(() => {
    if (selectedWeek != null) return
    if (weekOptions.length > 0) {
      setSelectedWeek(weekOptions[0].value)
    }
  }, [weekOptions, selectedWeek])

  useEffect(() => {
    setLinePreview(null)
    setCardFilter(null)
    setTableASort(null)
    setTableBSort(null)
  }, [selectedWeek])

  const linesQuery = useAdminPayrollLinesWeekly(selectedWeek ?? undefined)

  const locationsQuery = useQuery({
    queryKey: ['active-locations-for-import'],
    queryFn: rpcListActiveLocationsForImport,
  })
  const locations = locationsQuery.data ?? []

  const weekLines = linesQuery.data ?? []

  const cards = useMemo(() => aggregateWeekSummaryCards(weekLines), [weekLines])

  const linesForTables = useMemo(
    () => filterLinesForDashboardCard(weekLines, cardFilter),
    [weekLines, cardFilter],
  )

  const tableA = useMemo(
    () => aggregateTableAByStaff(linesForTables, locations),
    [linesForTables, locations],
  )

  const tableB = useMemo(
    () => aggregateTableBByStaff(linesForTables, locations),
    [linesForTables, locations],
  )

  const displayTableA = useMemo(
    () => sortWeeklyDashboardTableARows(tableA, tableASort),
    [tableA, tableASort],
  )

  const displayTableB = useMemo(
    () => sortWeeklyDashboardTableBRows(tableB, tableBSort),
    [tableB, tableBSort],
  )

  const totalsA = useMemo(
    () => ({
      profProd: sumColumn(tableA, 'profProd'),
      retailProd: sumColumn(tableA, 'retailProd'),
      services: sumColumn(tableA, 'services'),
      total: sumColumn(tableA, 'total'),
    }),
    [tableA],
  )

  const totalsB = useMemo(
    () => ({
      commProducts: sumColumn(tableB, 'commProducts'),
      commServices: sumColumn(tableB, 'commServices'),
      total: sumColumn(tableB, 'total'),
    }),
    [tableB],
  )

  const previewLines = useMemo(() => {
    if (!linePreview || !selectedWeek || !linesQuery.data) return []
    return filterAdminPayrollLinesForStaffWeek(linesQuery.data, {
      payWeekStart: selectedWeek,
      derivedStaffPaidId: linePreview.staffPaidId,
      staffLabel: linePreview.staffLabel,
    })
  }, [linePreview, selectedWeek, linesQuery.data])

  if (summaryQuery.isLoading) {
    return (
      <div data-testid="admin-weekly-commission-page">
        <LoadingState
          message="Loading pay weeks…"
          testId="admin-weekly-commission-loading"
        />
      </div>
    )
  }

  if (summaryQuery.isError) {
    const { message, err } = queryErrorDetail(summaryQuery.error)
    return (
      <div data-testid="admin-weekly-commission-page">
        <ErrorState
          title="Could not load pay weeks"
          error={err}
          message={message}
          onRetry={() => void summaryQuery.refetch()}
          testId="admin-weekly-commission-error"
        />
      </div>
    )
  }

  if (weekOptions.length === 0) {
    return (
      <div data-testid="admin-weekly-commission-page">
        <PageHeader
          title="Weekly commission dashboard"
          description="Commission and sales totals by pay week, grouped by staff."
        />
        <EmptyState
          title="No payroll weeks available"
          description="There is no admin weekly summary data yet. After payroll data exists, pay weeks will appear here."
          testId="admin-weekly-commission-empty-weeks"
        />
      </div>
    )
  }

  return (
    <div data-testid="admin-weekly-commission-page">
      <PageHeader
        title="Weekly payroll summary"
        description="Totals for a selected pay week. Choose the week below; figures refresh from line-level payroll data."
      />

      <div className="mb-6 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <label className="flex max-w-md flex-col gap-1.5 text-sm">
          <span className="font-medium text-slate-700">Pay week</span>
          <select
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
            value={selectedWeek ?? ''}
            onChange={(e) => setSelectedWeek(e.target.value || null)}
            data-testid="admin-weekly-commission-week-select"
          >
            {weekOptions.map((o) => (
              <option key={o.value} value={o.value}>
                {o.label}
              </option>
            ))}
          </select>
        </label>
      </div>

      {linesQuery.isLoading ? (
        <LoadingState
          message="Loading lines for selected week…"
          testId="admin-weekly-commission-lines-loading"
        />
      ) : linesQuery.isError ? (
        <ErrorState
          title="Could not load payroll lines"
          error={queryErrorDetail(linesQuery.error).err}
          message={queryErrorDetail(linesQuery.error).message}
          onRetry={() => void linesQuery.refetch()}
          testId="admin-weekly-commission-lines-error"
        />
      ) : (
        <>
          <div
            className="mb-8 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4"
            data-testid="admin-weekly-commission-cards"
          >
            <button
              type="button"
              className={`${cardButtonBase} ${
                cardFilter === 'commission' ? cardButtonActive : cardButtonIdle
              }`}
              aria-pressed={cardFilter === 'commission'}
              onClick={() =>
                setCardFilter((f) => (f === 'commission' ? null : 'commission'))
              }
              data-testid="admin-weekly-commission-card-commission"
            >
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
                Total actual commission
              </p>
              <p className="mt-1 text-2xl font-semibold tabular-nums text-slate-900">
                {formatNzd(cards.totalActualCommissionExGst)}
              </p>
            </button>
            <button
              type="button"
              className={`${cardButtonBase} ${
                cardFilter === 'sales' ? cardButtonActive : cardButtonIdle
              }`}
              aria-pressed={cardFilter === 'sales'}
              onClick={() => setCardFilter((f) => (f === 'sales' ? null : 'sales'))}
              data-testid="admin-weekly-commission-card-sales"
            >
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
                Total sales, ex GST
              </p>
              <p className="mt-1 text-2xl font-semibold tabular-nums text-slate-900">
                {formatNzd(cards.totalSalesExGst)}
              </p>
            </button>
            <button
              type="button"
              className={`${cardButtonBase} ${
                cardFilter === 'orewa' ? cardButtonActive : cardButtonIdle
              }`}
              aria-pressed={cardFilter === 'orewa'}
              onClick={() => setCardFilter((f) => (f === 'orewa' ? null : 'orewa'))}
              data-testid="admin-weekly-commission-card-orewa"
            >
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
                Orewa sales, ex GST
              </p>
              <p className="mt-1 text-2xl font-semibold tabular-nums text-slate-900">
                {formatNzd(cards.orewaSalesExGst)}
              </p>
            </button>
            <button
              type="button"
              className={`${cardButtonBase} ${
                cardFilter === 'takapuna' ? cardButtonActive : cardButtonIdle
              }`}
              aria-pressed={cardFilter === 'takapuna'}
              onClick={() =>
                setCardFilter((f) => (f === 'takapuna' ? null : 'takapuna'))
              }
              data-testid="admin-weekly-commission-card-takapuna"
            >
              <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
                Takapuna sales, ex GST
              </p>
              <p className="mt-1 text-2xl font-semibold tabular-nums text-slate-900">
                {formatNzd(cards.takapunaSalesExGst)}
              </p>
            </button>
          </div>

          <div className="grid grid-cols-1 gap-8 lg:grid-cols-2 lg:items-start">
          <section>
            <h2 className="mb-3 text-base font-semibold text-slate-900">
              By category (commission amount)
            </h2>
            <TableScrollArea>
              <table className={dashTable}>
                <thead>
                  <tr>
                    <th className={dashTh} scope="col">
                      <TableColumnSortHeader
                        label="Stylist paid"
                        columnKey="staffPaid"
                        sortState={tableASort}
                        onSortChange={setTableASort}
                      />
                    </th>
                    <th className={dashThRight} scope="col">
                      <TableColumnSortHeader
                        label="Prof. Prod."
                        columnKey="profProd"
                        sortState={tableASort}
                        onSortChange={setTableASort}
                        align="right"
                      />
                    </th>
                    <th className={dashThRight} scope="col">
                      <TableColumnSortHeader
                        label="Retail Prod."
                        columnKey="retailProd"
                        sortState={tableASort}
                        onSortChange={setTableASort}
                        align="right"
                      />
                    </th>
                    <th className={dashThRight} scope="col">
                      <TableColumnSortHeader
                        label="Services"
                        columnKey="services"
                        sortState={tableASort}
                        onSortChange={setTableASort}
                        align="right"
                      />
                    </th>
                    <th className={dashThRight} scope="col">
                      <TableColumnSortHeader
                        label="Total"
                        columnKey="total"
                        sortState={tableASort}
                        onSortChange={setTableASort}
                        align="right"
                      />
                    </th>
                    <th className={dashThAction} aria-hidden />
                  </tr>
                </thead>
                <tbody>
                  {tableA.length === 0 ? (
                    <tr>
                      <td colSpan={6} className={dashTdText}>
                        {weekLines.length === 0
                          ? 'No lines for this week.'
                          : 'No lines match the selected card filter.'}
                      </td>
                    </tr>
                  ) : (
                    <>
                      {displayTableA.map((r) => (
                        <tr key={r.staffPaid}>
                          <td className={dashTdName}>
                            <span className="flex items-center gap-1.5 whitespace-nowrap">
                              <StaffLocationNavBadge letter={r.locationBadge} />
                              <span className="font-medium whitespace-nowrap text-slate-900">
                                {r.staffPaid}
                              </span>
                            </span>
                          </td>
                          <td className={dashTdNumRight}>{formatNzd(r.profProd)}</td>
                          <td className={dashTdNumRight}>{formatNzd(r.retailProd)}</td>
                          <td className={dashTdNumRight}>{formatNzd(r.services)}</td>
                          <td className={dashTdNumRight}>
                            <span className="font-medium tabular-nums">{formatNzd(r.total)}</span>
                          </td>
                          <td className={dashTdAction}>
                            <button
                              type="button"
                              className="text-xs font-medium text-violet-700 hover:text-violet-900"
                              onClick={() =>
                                setLinePreview({
                                  staffLabel: r.staffPaid,
                                  staffPaidId: r.staffPaidId,
                                })
                              }
                              data-testid="admin-weekly-commission-preview-table-a"
                            >
                              Lines
                            </button>
                          </td>
                        </tr>
                      ))}
                      <tr className="bg-slate-50">
                        <td className={dashTdName}>
                          <span className="flex items-center gap-1.5 whitespace-nowrap">
                            <StaffLocationNavBadge letter={null} />
                            <span className="font-semibold whitespace-nowrap">Total</span>
                          </span>
                        </td>
                        <td className={`${dashTdNumRight} font-semibold`}>
                          {formatNzd(totalsA.profProd)}
                        </td>
                        <td className={`${dashTdNumRight} font-semibold`}>
                          {formatNzd(totalsA.retailProd)}
                        </td>
                        <td className={`${dashTdNumRight} font-semibold`}>
                          {formatNzd(totalsA.services)}
                        </td>
                        <td className={`${dashTdNumRight} font-semibold`}>
                          {formatNzd(totalsA.total)}
                        </td>
                        <td className={dashTdAction} aria-hidden />
                      </tr>
                    </>
                  )}
                </tbody>
              </table>
            </TableScrollArea>
          </section>

          <section>
            <h2 className="mb-3 text-base font-semibold text-slate-900">
              By commission product / service (commission amount)
            </h2>
            <TableScrollArea>
              <table className={dashTable}>
                <thead>
                  <tr>
                    <th className={dashTh} scope="col">
                      <TableColumnSortHeader
                        label="Stylist paid"
                        columnKey="staffPaid"
                        sortState={tableBSort}
                        onSortChange={setTableBSort}
                      />
                    </th>
                    <th className={dashThRight} scope="col">
                      <TableColumnSortHeader
                        label="Comm Products"
                        columnKey="commProducts"
                        sortState={tableBSort}
                        onSortChange={setTableBSort}
                        align="right"
                      />
                    </th>
                    <th className={dashThRight} scope="col">
                      <TableColumnSortHeader
                        label="Comm Services"
                        columnKey="commServices"
                        sortState={tableBSort}
                        onSortChange={setTableBSort}
                        align="right"
                      />
                    </th>
                    <th className={dashThRight} scope="col">
                      <TableColumnSortHeader
                        label="Total"
                        columnKey="total"
                        sortState={tableBSort}
                        onSortChange={setTableBSort}
                        align="right"
                      />
                    </th>
                    <th className={dashThAction} aria-hidden />
                  </tr>
                </thead>
                <tbody>
                  {tableB.length === 0 ? (
                    <tr>
                      <td colSpan={5} className={dashTdText}>
                        {weekLines.length === 0
                          ? 'No lines for this week.'
                          : 'No lines match the selected card filter.'}
                      </td>
                    </tr>
                  ) : (
                    <>
                      {displayTableB.map((r) => (
                        <tr key={r.staffPaid}>
                          <td className={dashTdName}>
                            <span className="flex items-center gap-1.5 whitespace-nowrap">
                              <StaffLocationNavBadge letter={r.locationBadge} />
                              <span className="font-medium whitespace-nowrap text-slate-900">
                                {r.staffPaid}
                              </span>
                            </span>
                          </td>
                          <td className={dashTdNumRight}>{formatNzd(r.commProducts)}</td>
                          <td className={dashTdNumRight}>{formatNzd(r.commServices)}</td>
                          <td className={dashTdNumRight}>
                            <span className="font-medium tabular-nums">{formatNzd(r.total)}</span>
                          </td>
                          <td className={dashTdAction}>
                            <button
                              type="button"
                              className="text-xs font-medium text-violet-700 hover:text-violet-900"
                              onClick={() =>
                                setLinePreview({
                                  staffLabel: r.staffPaid,
                                  staffPaidId: r.staffPaidId,
                                })
                              }
                              data-testid="admin-weekly-commission-preview-table-b"
                            >
                              Lines
                            </button>
                          </td>
                        </tr>
                      ))}
                      <tr className="bg-slate-50">
                        <td className={dashTdName}>
                          <span className="flex items-center gap-1.5 whitespace-nowrap">
                            <StaffLocationNavBadge letter={null} />
                            <span className="font-semibold whitespace-nowrap">Total</span>
                          </span>
                        </td>
                        <td className={`${dashTdNumRight} font-semibold`}>
                          {formatNzd(totalsB.commProducts)}
                        </td>
                        <td className={`${dashTdNumRight} font-semibold`}>
                          {formatNzd(totalsB.commServices)}
                        </td>
                        <td className={`${dashTdNumRight} font-semibold`}>
                          {formatNzd(totalsB.total)}
                        </td>
                        <td className={dashTdAction} aria-hidden />
                      </tr>
                    </>
                  )}
                </tbody>
              </table>
            </TableScrollArea>
          </section>
          </div>

          <AdminPayrollLinesPreviewModal
            open={linePreview != null}
            onClose={() => setLinePreview(null)}
            payWeekStart={selectedWeek ?? ''}
            staffLabel={linePreview?.staffLabel ?? ''}
            lines={previewLines}
            isLoading={linesQuery.isLoading}
          />
        </>
      )}
    </div>
  )
}
