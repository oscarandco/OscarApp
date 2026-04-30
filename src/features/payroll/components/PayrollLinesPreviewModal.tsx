import { useQuery } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'

import { TableColumnSortHeader } from '@/components/ui/TableColumnSortHeader'

import { PayrollLineStats } from '@/features/payroll/components/PayrollLineStats'
import type { WeeklyCommissionLineRow, WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { filterCommissionLinesForSummaryRow } from '@/lib/payrollSummaryFilters'
import { stylistPaidFromLine, workPerformedByFromLine } from '@/lib/payrollLineDisplay'
import { rpcGetMyCommissionLinesWeekly } from '@/lib/supabaseRpc'
import type { ColumnSortState } from '@/lib/tableSort'
import { sortCommissionLinePreviewRows } from '@/lib/payrollLineTableSort'
import {
  formatCommissionRatePercent,
  formatNzd,
  formatShortDate,
} from '@/lib/formatters'

type PayrollLinesPreviewModalProps = {
  summaryRow: WeeklyCommissionSummaryRow | null
  onClose: () => void
}

const thBase =
  'border-b border-slate-200 px-1.5 py-1 align-top text-xs font-semibold leading-snug text-slate-700'
const thLeft = `${thBase} text-left`
const thRight = `${thBase} text-right`
const tdBase =
  'border-b border-slate-100 px-1.5 py-1 align-top text-xs leading-tight text-slate-800'

function previewRowKey(row: WeeklyCommissionLineRow, index: number): string {
  if (row.id != null && String(row.id).trim() !== '') return `id:${String(row.id)}`
  return `i:${index}`
}

export function PayrollLinesPreviewModal({
  summaryRow,
  onClose,
}: PayrollLinesPreviewModalProps) {
  const payWeek =
    summaryRow != null && String(summaryRow.pay_week_start ?? '').trim() !== ''
      ? String(summaryRow.pay_week_start).trim()
      : ''

  const open = summaryRow != null && payWeek !== ''

  const linesQuery = useQuery({
    queryKey: ['my-commission-lines-weekly', payWeek] as const,
    queryFn: () => rpcGetMyCommissionLinesWeekly(payWeek),
    enabled: open,
  })

  const filtered = useMemo(() => {
    if (!summaryRow || !linesQuery.data) return []
    return filterCommissionLinesForSummaryRow(summaryRow, linesQuery.data)
  }, [summaryRow, linesQuery.data])

  const [previewSort, setPreviewSort] = useState<ColumnSortState>(null)

  const sortedPreview = useMemo(
    () => sortCommissionLinePreviewRows(filtered, previewSort),
    [filtered, previewSort],
  )

  useEffect(() => {
    setPreviewSort(null)
  }, [summaryRow])

  useEffect(() => {
    if (!open) return
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open || summaryRow == null) {
    return null
  }

  const locationLabel =
    summaryRow.location_name != null && String(summaryRow.location_name).trim() !== ''
      ? String(summaryRow.location_name).trim()
      : summaryRow.location_id != null
        ? String(summaryRow.location_id)
        : '—'

  const staffLabel =
    summaryRow.derived_staff_paid_display_name != null &&
    String(summaryRow.derived_staff_paid_display_name).trim() !== ''
      ? String(summaryRow.derived_staff_paid_display_name).trim()
      : summaryRow.derived_staff_paid_full_name != null
        ? String(summaryRow.derived_staff_paid_full_name).trim()
        : '—'

  const fullReportHref = `/app/my-sales/${encodeURIComponent(payWeek)}`

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 px-4 py-8"
      role="dialog"
      aria-modal="true"
      aria-labelledby="payroll-lines-preview-title"
      data-testid="payroll-lines-preview-modal"
      onClick={onClose}
    >
      <div
        className="flex max-h-[90vh] w-full max-w-[min(88rem,calc(100vw-2rem))] flex-col overflow-hidden rounded-xl border border-slate-200 bg-white shadow-lg"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex shrink-0 items-start justify-between gap-4 border-b border-slate-100 px-5 py-4">
          <div className="min-w-0">
            <h2
              id="payroll-lines-preview-title"
              className="text-lg font-semibold text-slate-900"
            >
              Line preview
            </h2>
            <p className="mt-1 text-sm text-slate-600">
              <span className="font-medium text-slate-800">
                {formatShortDate(payWeek)}
              </span>
              <span className="text-slate-400"> · </span>
              <span>{locationLabel}</span>
              <span className="text-slate-400"> · </span>
              <span>{staffLabel}</span>
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="shrink-0 rounded-md border border-slate-200 bg-white px-2 py-1 text-sm text-slate-600 hover:bg-slate-50"
            aria-label="Close"
          >
            ✕
          </button>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">
          {linesQuery.isLoading ? (
            <p className="text-sm text-slate-600">Loading lines…</p>
          ) : linesQuery.isError ? (
            <p className="text-sm text-red-700">
              Could not load lines. Use the full report link below or try again later.
            </p>
          ) : (
            <>
              <PayrollLineStats rows={filtered} />
              {filtered.length === 0 ? (
                <p className="mt-4 text-sm text-slate-600">
                  No line items matched this summary row for the selected week, location,
                  and staff. Open the full report to see all lines for the week.
                </p>
              ) : (
                <div className="mt-4 overflow-x-auto rounded-lg border border-slate-200">
                  <table className="w-full min-w-[820px] border-collapse text-left text-xs">
                    <thead className="bg-slate-50">
                      <tr>
                        <th className={`${thLeft} w-[1%] max-w-[5.5rem]`} scope="col">
                          <TableColumnSortHeader
                            label="Invoice"
                            columnKey="invoice"
                            sortState={previewSort}
                            onSortChange={setPreviewSort}
                            wrapLabel
                          />
                        </th>
                        <th className={`${thLeft} w-[1%] whitespace-nowrap`} scope="col">
                          <TableColumnSortHeader
                            label="Sale date"
                            columnKey="sale_date"
                            sortState={previewSort}
                            onSortChange={setPreviewSort}
                            wrapLabel
                          />
                        </th>
                        <th className={thLeft} scope="col">
                          <TableColumnSortHeader
                            label="Customer"
                            columnKey="customer_name"
                            sortState={previewSort}
                            onSortChange={setPreviewSort}
                            wrapLabel
                          />
                        </th>
                        <th className={`${thLeft} max-w-[12rem]`} scope="col">
                          <TableColumnSortHeader
                            label="Product / service"
                            columnKey="product_service_name"
                            sortState={previewSort}
                            onSortChange={setPreviewSort}
                            wrapLabel
                          />
                        </th>
                        <th className={`${thLeft} max-w-[7.5rem]`} scope="col">
                          <TableColumnSortHeader
                            label="Work performed by"
                            columnKey="work_performed_by"
                            sortState={previewSort}
                            onSortChange={setPreviewSort}
                            wrapLabel
                          />
                        </th>
                        <th className={`${thLeft} max-w-[7.5rem]`} scope="col">
                          <TableColumnSortHeader
                            label="Stylist paid"
                            columnKey="stylist_paid"
                            sortState={previewSort}
                            onSortChange={setPreviewSort}
                            wrapLabel
                          />
                        </th>
                        <th className={`${thRight} w-[1%] whitespace-nowrap`} scope="col">
                          <TableColumnSortHeader
                            label="Price ex GST"
                            columnKey="price_ex_gst"
                            sortState={previewSort}
                            onSortChange={setPreviewSort}
                            align="right"
                            wrapLabel={false}
                          />
                        </th>
                        <th className={`${thRight} w-[1%] whitespace-nowrap`} scope="col">
                          <TableColumnSortHeader
                            label="Price incl GST"
                            columnKey="price_incl_gst"
                            sortState={previewSort}
                            onSortChange={setPreviewSort}
                            align="right"
                            wrapLabel={false}
                          />
                        </th>
                        <th className={`${thRight} w-[1%] whitespace-nowrap`} scope="col">
                          <TableColumnSortHeader
                            label="Rate"
                            columnKey="actual_commission_rate"
                            sortState={previewSort}
                            onSortChange={setPreviewSort}
                            align="right"
                            wrapLabel={false}
                          />
                        </th>
                        <th className={`${thRight} w-[1%]`} scope="col">
                          <TableColumnSortHeader
                            label="Actual commission"
                            columnKey="actual_commission"
                            sortState={previewSort}
                            onSortChange={setPreviewSort}
                            align="right"
                            wrapLabel={false}
                          />
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {sortedPreview.map((row, index) => {
                        const raw = row as Record<string, unknown>
                        const comm =
                          raw.actual_commission_amt_ex_gst ??
                          raw.actual_commission_amount
                        const workBy = workPerformedByFromLine(row)
                        const paid = stylistPaidFromLine(row)
                        const invoiceStr = row.invoice != null ? String(row.invoice) : ''
                        const productStr =
                          row.product_service_name != null
                            ? String(row.product_service_name)
                            : ''
                        return (
                          <tr
                            key={previewRowKey(row, index)}
                            className="odd:bg-white even:bg-slate-50/80"
                          >
                            <td
                              className={`${tdBase} max-w-[5.5rem] min-w-0`}
                              title={invoiceStr !== '' ? invoiceStr : undefined}
                            >
                              <span className="block truncate whitespace-nowrap">
                                {invoiceStr !== '' ? invoiceStr : '—'}
                              </span>
                            </td>
                            <td className={`${tdBase} whitespace-nowrap`}>
                              {row.sale_date
                                ? formatShortDate(String(row.sale_date))
                                : '—'}
                            </td>
                            <td className={`${tdBase} min-w-0`}>{row.customer_name ?? '—'}</td>
                            <td
                              className={`${tdBase} max-w-[12rem] min-w-0`}
                              title={productStr !== '' ? productStr : undefined}
                            >
                              <span className="block truncate">
                                {productStr !== '' ? productStr : '—'}
                              </span>
                            </td>
                            <td
                              className={`${tdBase} max-w-[7.5rem] min-w-0`}
                              title={workBy !== '' ? workBy : undefined}
                            >
                              <span className="block truncate whitespace-nowrap">
                                {workBy !== '' ? workBy : '—'}
                              </span>
                            </td>
                            <td
                              className={`${tdBase} max-w-[7.5rem] min-w-0`}
                              title={paid !== '' ? paid : undefined}
                            >
                              <span className="block truncate whitespace-nowrap">
                                {paid !== '' ? paid : '—'}
                              </span>
                            </td>
                            <td className={`${tdBase} whitespace-nowrap text-right tabular-nums`}>
                              {row.price_ex_gst != null && row.price_ex_gst !== ''
                                ? formatNzd(row.price_ex_gst)
                                : '—'}
                            </td>
                            <td className={`${tdBase} whitespace-nowrap text-right tabular-nums`}>
                              {row.price_incl_gst != null && row.price_incl_gst !== ''
                                ? formatNzd(row.price_incl_gst)
                                : '—'}
                            </td>
                            <td className={`${tdBase} whitespace-nowrap text-right tabular-nums`}>
                              {raw.actual_commission_rate != null
                                ? formatCommissionRatePercent(raw.actual_commission_rate)
                                : '—'}
                            </td>
                            <td className={`${tdBase} whitespace-nowrap text-right tabular-nums`}>
                              {comm != null && comm !== '' ? formatNzd(comm) : '—'}
                            </td>
                          </tr>
                        )
                      })}
                    </tbody>
                  </table>
                </div>
              )}
            </>
          )}
        </div>

        <div className="flex shrink-0 flex-wrap items-center justify-end gap-2 border-t border-slate-100 px-5 py-3">
          <button
            type="button"
            onClick={onClose}
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 shadow-sm hover:bg-slate-50"
          >
            Close
          </button>
          <Link
            to={fullReportHref}
            className="rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700"
            data-testid="payroll-lines-preview-full-report"
          >
            Go to full report
          </Link>
        </div>
      </div>
    </div>
  )
}
