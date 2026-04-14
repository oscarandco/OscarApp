import { useEffect, useMemo, useState } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { TableScrollArea } from '@/components/ui/TableScrollArea'
import { AdminPayrollLinesPreviewModal } from '@/features/admin/components/AdminPayrollLinesPreviewModal'
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
import {
  filterAdminPayrollLinesForStaffWeek,
  uniquePayWeekStartOptions,
} from '@/lib/payrollSummaryFilters'
import { queryErrorDetail } from '@/lib/queryError'

const thBase =
  'border-b border-slate-200 px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-4 sm:py-3 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700'
const tdBase =
  'whitespace-nowrap border-b border-slate-100 px-3 py-2.5 text-slate-700 sm:px-4 sm:py-3 tabular-nums'
const tdText = 'border-b border-slate-100 px-3 py-2.5 text-slate-700 sm:px-4 sm:py-3'
/** First column: full names can wrap when tables are side-by-side on lg+ */
const tdName =
  'min-w-0 border-b border-slate-100 px-3 py-2.5 text-slate-700 sm:px-4 sm:py-3 break-words'
/** Rightmost actions column: no visible header label */
const thAction = `${thBase} w-px`
const tdAction =
  'whitespace-nowrap border-b border-slate-100 px-3 py-2.5 text-right align-middle text-slate-700 sm:px-4 sm:py-3'

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

  useEffect(() => {
    if (selectedWeek != null) return
    if (weekOptions.length > 0) {
      setSelectedWeek(weekOptions[0].value)
    }
  }, [weekOptions, selectedWeek])

  useEffect(() => {
    setLinePreview(null)
    setCardFilter(null)
  }, [selectedWeek])

  const linesQuery = useAdminPayrollLinesWeekly(selectedWeek ?? undefined)

  const weekLines = linesQuery.data ?? []

  const cards = useMemo(() => aggregateWeekSummaryCards(weekLines), [weekLines])

  const linesForTables = useMemo(
    () => filterLinesForDashboardCard(weekLines, cardFilter),
    [weekLines, cardFilter],
  )

  const tableA = useMemo(() => aggregateTableAByStaff(linesForTables), [linesForTables])

  const tableB = useMemo(() => aggregateTableBByStaff(linesForTables), [linesForTables])

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
        title="Weekly commission dashboard"
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
              <table className="min-w-full border-collapse">
                <thead>
                  <tr>
                    <th className={thBase}>Staff paid</th>
                    <th className={`${thBase} text-right`}>Prof. Prod.</th>
                    <th className={`${thBase} text-right`}>Retail Prod.</th>
                    <th className={`${thBase} text-right`}>Services</th>
                    <th className={`${thBase} text-right`}>Total</th>
                    <th className={thAction} aria-hidden />
                  </tr>
                </thead>
                <tbody>
                  {tableA.length === 0 ? (
                    <tr>
                      <td colSpan={6} className={tdText}>
                        {weekLines.length === 0
                          ? 'No lines for this week.'
                          : 'No lines match the selected card filter.'}
                      </td>
                    </tr>
                  ) : (
                    <>
                      {tableA.map((r) => (
                        <tr key={r.staffPaid}>
                          <td className={tdName}>{r.staffPaid}</td>
                          <td className={`${tdBase} text-right`}>{formatNzd(r.profProd)}</td>
                          <td className={`${tdBase} text-right`}>{formatNzd(r.retailProd)}</td>
                          <td className={`${tdBase} text-right`}>{formatNzd(r.services)}</td>
                          <td className={`${tdBase} text-right`}>
                            <span className="font-medium tabular-nums">{formatNzd(r.total)}</span>
                          </td>
                          <td className={tdAction}>
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
                        <td className={`${tdText} font-semibold`}>Total</td>
                        <td className={`${tdBase} text-right font-semibold`}>
                          {formatNzd(totalsA.profProd)}
                        </td>
                        <td className={`${tdBase} text-right font-semibold`}>
                          {formatNzd(totalsA.retailProd)}
                        </td>
                        <td className={`${tdBase} text-right font-semibold`}>
                          {formatNzd(totalsA.services)}
                        </td>
                        <td className={`${tdBase} text-right font-semibold`}>
                          {formatNzd(totalsA.total)}
                        </td>
                        <td className={tdAction} aria-hidden />
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
              <table className="min-w-full border-collapse">
                <thead>
                  <tr>
                    <th className={thBase}>Staff paid</th>
                    <th className={`${thBase} text-right`}>Comm Products</th>
                    <th className={`${thBase} text-right`}>Comm Services</th>
                    <th className={`${thBase} text-right`}>Total</th>
                    <th className={thAction} aria-hidden />
                  </tr>
                </thead>
                <tbody>
                  {tableB.length === 0 ? (
                    <tr>
                      <td colSpan={5} className={tdText}>
                        {weekLines.length === 0
                          ? 'No lines for this week.'
                          : 'No lines match the selected card filter.'}
                      </td>
                    </tr>
                  ) : (
                    <>
                      {tableB.map((r) => (
                        <tr key={r.staffPaid}>
                          <td className={tdName}>{r.staffPaid}</td>
                          <td className={`${tdBase} text-right`}>
                            {formatNzd(r.commProducts)}
                          </td>
                          <td className={`${tdBase} text-right`}>
                            {formatNzd(r.commServices)}
                          </td>
                          <td className={`${tdBase} text-right`}>
                            <span className="font-medium tabular-nums">{formatNzd(r.total)}</span>
                          </td>
                          <td className={tdAction}>
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
                        <td className={`${tdText} font-semibold`}>Total</td>
                        <td className={`${tdBase} text-right font-semibold`}>
                          {formatNzd(totalsB.commProducts)}
                        </td>
                        <td className={`${tdBase} text-right font-semibold`}>
                          {formatNzd(totalsB.commServices)}
                        </td>
                        <td className={`${tdBase} text-right font-semibold`}>
                          {formatNzd(totalsB.total)}
                        </td>
                        <td className={tdAction} aria-hidden />
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
