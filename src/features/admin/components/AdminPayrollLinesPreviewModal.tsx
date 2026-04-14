import { useEffect } from 'react'
import { Link } from 'react-router-dom'

import { PayrollLineStats } from '@/features/payroll/components/PayrollLineStats'
import type { WeeklyCommissionLineRow } from '@/features/payroll/types'
import {
  formatCommissionRatePercent,
  formatNzd,
  formatShortDate,
} from '@/lib/formatters'

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

const th =
  'border-b border-slate-200 px-2 py-2 text-left text-xs font-semibold text-slate-700'
const td = 'border-b border-slate-100 px-2 py-1.5 text-sm text-slate-800'

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
  const adminWeekHref = `/app/admin/payroll/${encodeURIComponent(pw)}`

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
        className="flex max-h-[90vh] w-full max-w-4xl flex-col overflow-hidden rounded-xl border border-slate-200 bg-white shadow-lg"
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
                  <table className="w-full min-w-[640px] border-collapse text-left text-sm">
                    <thead className="bg-slate-50">
                      <tr>
                        <th className={th}>Invoice</th>
                        <th className={th}>Sale date</th>
                        <th className={th}>Customer</th>
                        <th className={th}>Product / service</th>
                        <th className={th}>Price ex GST</th>
                        <th className={th}>Rate</th>
                        <th className={th}>Actual commission</th>
                      </tr>
                    </thead>
                    <tbody>
                      {lines.map((row, index) => {
                        const raw = row as Record<string, unknown>
                        const comm =
                          raw.actual_commission_amt_ex_gst ?? raw.actual_commission_amount
                        return (
                          <tr
                            key={previewRowKey(row, index)}
                            className="odd:bg-white even:bg-slate-50/80"
                          >
                            <td className={td}>{row.invoice ?? '—'}</td>
                            <td className={`${td} whitespace-nowrap`}>
                              {row.sale_date ? formatShortDate(String(row.sale_date)) : '—'}
                            </td>
                            <td className={td}>{row.customer_name ?? '—'}</td>
                            <td className={td}>{row.product_service_name ?? '—'}</td>
                            <td className={`${td} tabular-nums`}>
                              {row.price_ex_gst != null && row.price_ex_gst !== ''
                                ? formatNzd(row.price_ex_gst)
                                : '—'}
                            </td>
                            <td className={`${td} tabular-nums`}>
                              {raw.actual_commission_rate != null
                                ? formatCommissionRatePercent(raw.actual_commission_rate)
                                : '—'}
                            </td>
                            <td className={`${td} tabular-nums`}>
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
