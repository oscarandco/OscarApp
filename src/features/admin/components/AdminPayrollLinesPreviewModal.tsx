import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'

import { TableColumnSortHeader } from '@/components/ui/TableColumnSortHeader'
import { PayrollLineStats } from '@/features/payroll/components/PayrollLineStats'
import type { WeeklyCommissionLineRow } from '@/features/payroll/types'
import {
  formatCommissionRatePercent,
  formatNzd,
  formatShortDate,
} from '@/lib/formatters'
import { stylistPaidFromLine, workPerformedByFromLine } from '@/lib/payrollLineDisplay'
import { sortCommissionLinePreviewRows } from '@/lib/payrollLineTableSort'
import type { ColumnSortState } from '@/lib/tableSort'

export type AdminPayrollLinesPreviewModalProps = {
  open: boolean
  onClose: () => void
  payWeekStart: string
  /** Full name (or display) shown in the dashboard row — subtitle only. */
  staffLabel: string
  /** Pre-filtered lines for this week + staff (all locations). */
  lines: WeeklyCommissionLineRow[]
  isLoading?: boolean
}

/** Dense preview table — smaller type and padding than the main Sales Summary grid. */
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

export function AdminPayrollLinesPreviewModal({
  open,
  onClose,
  payWeekStart,
  staffLabel,
  lines,
  isLoading = false,
}: AdminPayrollLinesPreviewModalProps) {
  const [previewSort, setPreviewSort] = useState<ColumnSortState>(null)

  const sortedLines = useMemo(
    () => sortCommissionLinePreviewRows(lines, previewSort),
    [lines, previewSort],
  )

  useEffect(() => {
    if (!open) setPreviewSort(null)
  }, [open])

  useEffect(() => {
    if (!open) return
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) {
    return null
  }

  const pw = String(payWeekStart).trim()
  const adminWeekHref = `/app/admin/sales-summary/${encodeURIComponent(pw)}`

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 px-4 py-8"
      role="dialog"
      aria-modal="true"
      aria-labelledby="admin-payroll-lines-preview-title"
      data-testid="admin-payroll-lines-preview-modal"
      onClick={onClose}
    >
      <div
        className="flex max-h-[90vh] w-full max-w-[min(88rem,calc(100vw-2rem))] flex-col overflow-hidden rounded-xl border border-slate-200 bg-white shadow-lg"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex shrink-0 items-start justify-between gap-4 border-b border-slate-100 px-5 py-4">
          <div className="min-w-0">
            <h2
              id="admin-payroll-lines-preview-title"
              className="text-lg font-semibold text-slate-900"
            >
              Line preview
            </h2>
            <p className="mt-1 text-sm text-slate-600">
              <span className="font-medium text-slate-800">{formatShortDate(pw)}</span>
              <span className="text-slate-400"> · </span>
              <span>{staffLabel}</span>
              <span className="text-slate-400"> · </span>
              <span className="text-slate-500">All locations</span>
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
          {isLoading ? (
            <p className="text-sm text-slate-600">Loading lines…</p>
          ) : (
            <>
              <PayrollLineStats rows={lines} />
              {lines.length === 0 ? (
                <p className="mt-4 text-sm text-slate-600">
                  No line items matched this staff member for the selected week. Open the
                  full week report to see all lines.
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
                      {sortedLines.map((row, index) => {
                        const raw = row as Record<string, unknown>
                        const comm =
                          raw.actual_commission_amt_ex_gst ?? raw.actual_commission_amount
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
                              {row.sale_date ? formatShortDate(String(row.sale_date)) : '—'}
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
            to={adminWeekHref}
            className="rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700"
            data-testid="admin-payroll-lines-preview-full-week"
          >
            Go to full week report
          </Link>
        </div>
      </div>
    </div>
  )
}
