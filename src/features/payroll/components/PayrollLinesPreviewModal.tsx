import { useQuery } from '@tanstack/react-query'
import { useEffect, useMemo } from 'react'
import { Link } from 'react-router-dom'

import { PayrollLineStats } from '@/features/payroll/components/PayrollLineStats'
import type { WeeklyCommissionLineRow, WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { filterCommissionLinesForSummaryRow } from '@/lib/payrollSummaryFilters'
import { stylistPaidFromLine, workPerformedByFromLine } from '@/lib/payrollLineDisplay'
import { rpcGetMyCommissionLinesWeekly } from '@/lib/supabaseRpc'
import {
  formatCommissionRatePercent,
  formatNzd,
  formatShortDate,
} from '@/lib/formatters'

type PayrollLinesPreviewModalProps = {
  summaryRow: WeeklyCommissionSummaryRow | null
  onClose: () => void
}

const th =
  'border-b border-slate-200 px-2 py-2 text-left text-xs font-semibold text-slate-700'
const td = 'border-b border-slate-100 px-2 py-1.5 text-sm text-slate-800'

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
        className="flex max-h-[90vh] w-full max-w-4xl flex-col overflow-hidden rounded-xl border border-slate-200 bg-white shadow-lg"
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
                  <table className="w-full min-w-[880px] border-collapse text-left text-sm">
                    <thead className="bg-slate-50">
                      <tr>
                        <th className={th}>Invoice</th>
                        <th className={th}>Sale date</th>
                        <th className={th}>Customer</th>
                        <th className={th}>Product / service</th>
                        <th className={th}>Work performed by</th>
                        <th className={th}>Stylist paid</th>
                        <th className={th}>Price ex GST</th>
                        <th className={th}>Rate</th>
                        <th className={th}>Actual commission</th>
                      </tr>
                    </thead>
                    <tbody>
                      {filtered.map((row, index) => {
                        const raw = row as Record<string, unknown>
                        const comm =
                          raw.actual_commission_amt_ex_gst ??
                          raw.actual_commission_amount
                        const workBy = workPerformedByFromLine(row)
                        const paid = stylistPaidFromLine(row)
                        return (
                          <tr key={previewRowKey(row, index)} className="odd:bg-white even:bg-slate-50/80">
                            <td className={td}>{row.invoice ?? '—'}</td>
                            <td className={`${td} whitespace-nowrap`}>
                              {row.sale_date
                                ? formatShortDate(String(row.sale_date))
                                : '—'}
                            </td>
                            <td className={td}>{row.customer_name ?? '—'}</td>
                            <td className={td}>{row.product_service_name ?? '—'}</td>
                            <td className={td}>{workBy !== '' ? workBy : '—'}</td>
                            <td className={td}>{paid !== '' ? paid : '—'}</td>
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
                              {comm != null && comm !== ''
                                ? formatNzd(comm)
                                : '—'}
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
