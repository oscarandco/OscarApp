import { useEffect } from 'react'

import type { VoucherSalesDetailRow } from '@/features/payroll/types'
import { formatNzd, formatShortDate } from '@/lib/formatters'

export type VoucherSalesDetailModalProps = {
  open: boolean
  onClose: () => void
  scopeLabel: string
  totalExGst: number
  rows: VoucherSalesDetailRow[]
  isLoading?: boolean
  isError?: boolean
}

function locationLabel(row: VoucherSalesDetailRow): string {
  const name = String(row.location_name ?? '').trim()
  if (name !== '') return name
  const id = String(row.location_id ?? '').trim()
  return id !== '' ? id : '—'
}

function detailRowKey(row: VoucherSalesDetailRow, index: number): string {
  const invoice = String(row.invoice ?? '').trim()
  const date = String(row.sale_date ?? '').trim()
  const product = String(row.product_service_name ?? '').trim()
  if (invoice !== '' || date !== '' || product !== '') {
    return `${date}|${invoice}|${product}|${index}`
  }
  return `i:${index}`
}

export function VoucherSalesDetailModal({
  open,
  onClose,
  scopeLabel,
  totalExGst,
  rows,
  isLoading = false,
  isError = false,
}: VoucherSalesDetailModalProps) {
  useEffect(() => {
    if (!open) return
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) return null

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 px-4 py-8"
      role="dialog"
      aria-modal="true"
      aria-labelledby="voucher-sales-detail-title"
      data-testid="voucher-sales-detail-modal"
      onClick={onClose}
    >
      <div
        className="flex max-h-[90vh] w-full max-w-4xl flex-col overflow-hidden rounded-xl border border-slate-200 bg-white shadow-lg"
        onClick={(e) => e.stopPropagation()}
      >
        <div className="flex shrink-0 items-start justify-between gap-4 border-b border-slate-100 px-5 py-4">
          <div className="min-w-0">
            <h2
              id="voucher-sales-detail-title"
              className="text-lg font-semibold text-slate-900"
            >
              Voucher sales excluded — {scopeLabel}
            </h2>
            <p className="mt-1 text-sm text-slate-600">
              Total excluded:{' '}
              <span className="font-medium tabular-nums text-slate-800">
                {formatNzd(totalExGst)}
              </span>
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="shrink-0 rounded-md border border-slate-200 bg-white px-2 py-1 text-sm text-slate-600 hover:bg-slate-50"
            aria-label="Close"
            data-testid="voucher-sales-detail-close"
          >
            ✕
          </button>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto px-5 py-4">
          {isLoading ? (
            <p className="text-sm text-slate-600" data-testid="voucher-sales-detail-loading">
              Loading voucher sales…
            </p>
          ) : isError ? (
            <p className="text-sm text-red-700" data-testid="voucher-sales-detail-error">
              Could not load voucher sales.
            </p>
          ) : rows.length === 0 ? (
            <p className="text-sm text-slate-600" data-testid="voucher-sales-detail-empty">
              No voucher sales for this period.
            </p>
          ) : (
            <div className="overflow-x-auto">
              <table
                className="w-full min-w-[36rem] border-collapse text-left text-xs"
                data-testid="voucher-sales-detail-table"
              >
                <thead>
                  <tr>
                    <th className="border-b border-slate-200 px-2 py-2 font-semibold text-slate-700">
                      Sale date
                    </th>
                    <th className="border-b border-slate-200 px-2 py-2 font-semibold text-slate-700">
                      Location
                    </th>
                    <th className="border-b border-slate-200 px-2 py-2 font-semibold text-slate-700">
                      Invoice
                    </th>
                    <th className="border-b border-slate-200 px-2 py-2 font-semibold text-slate-700">
                      Customer
                    </th>
                    <th className="border-b border-slate-200 px-2 py-2 font-semibold text-slate-700">
                      Product / service
                    </th>
                    <th className="border-b border-slate-200 px-2 py-2 text-right font-semibold text-slate-700">
                      Price ex GST
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {rows.map((row, index) => (
                    <tr key={detailRowKey(row, index)}>
                      <td className="border-b border-slate-100 px-2 py-2 text-slate-800">
                        {row.sale_date ? formatShortDate(row.sale_date) : '—'}
                      </td>
                      <td className="border-b border-slate-100 px-2 py-2 text-slate-800">
                        {locationLabel(row)}
                      </td>
                      <td className="border-b border-slate-100 px-2 py-2 text-slate-800">
                        {row.invoice?.trim() ? row.invoice : '—'}
                      </td>
                      <td className="border-b border-slate-100 px-2 py-2 text-slate-800">
                        {row.customer_name?.trim() ? row.customer_name : '—'}
                      </td>
                      <td className="border-b border-slate-100 px-2 py-2 text-slate-800">
                        {row.product_service_name?.trim()
                          ? row.product_service_name
                          : '—'}
                      </td>
                      <td className="border-b border-slate-100 px-2 py-2 text-right tabular-nums text-slate-800">
                        {formatNzd(row.price_ex_gst)}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
