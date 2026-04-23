import { useEffect, useMemo } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import type { KpiInvoiceDetailRow } from '@/features/kpi/data/kpiApi'
import { useKpiInvoiceDetail } from '@/features/kpi/hooks/useKpiInvoiceDetail'
import { titleCaseGuestName } from '@/features/kpi/kpiLabels'
import { formatNzd, formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'

export type InvoiceDetailModalProps = {
  open: boolean
  onClose: () => void
  invoice: string | null
  locationId: string | null
  saleDate: string | null
}

/**
 * Popup showing every line on an invoice for the KPI drilldown
 * underlying-rows tables. Opened from the sales-line drilldown tables
 * (revenue / assistant_utilisation_ratio) via the per-row
 * "View invoice" button. Closes without navigating away from the KPI
 * page.
 */
export function InvoiceDetailModal(props: InvoiceDetailModalProps) {
  const { open, onClose, invoice, locationId, saleDate } = props

  const query = useKpiInvoiceDetail({
    invoice: invoice ?? undefined,
    locationId,
    saleDate,
    enabled: open,
  })

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
      className="fixed inset-0 z-50 flex items-end justify-center bg-black/40 p-2 sm:items-center sm:p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="invoice-detail-title"
      onClick={onClose}
    >
      <div
        className="flex w-full max-w-3xl flex-col overflow-hidden rounded-lg border border-slate-200 bg-white shadow-lg"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex items-start justify-between gap-3 border-b border-slate-200 px-5 py-4">
          <div className="min-w-0">
            <p className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">
              Invoice detail
            </p>
            <h2
              id="invoice-detail-title"
              className="mt-0.5 truncate text-lg font-semibold text-slate-900"
              data-testid="invoice-detail-title"
            >
              {invoice ? invoice : '—'}
            </h2>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="shrink-0 rounded-md border border-slate-200 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 hover:bg-slate-50"
            data-testid="invoice-detail-close"
          >
            Close
          </button>
        </header>

        <div className="max-h-[calc(100vh-8rem)] overflow-auto px-5 py-4">
          <InvoiceDetailBody
            invoice={invoice}
            isLoading={query.isLoading}
            isError={query.isError}
            error={query.error}
            refetch={() => query.refetch()}
            rows={query.data ?? []}
            fallbackSaleDate={saleDate}
          />
        </div>
      </div>
    </div>
  )
}

function InvoiceDetailBody(props: {
  invoice: string | null
  isLoading: boolean
  isError: boolean
  error: unknown
  refetch: () => void
  rows: KpiInvoiceDetailRow[]
  fallbackSaleDate: string | null
}) {
  const {
    invoice,
    isLoading,
    isError,
    error,
    refetch,
    rows,
    fallbackSaleDate,
  } = props

  const summary = useMemo(() => {
    if (rows.length === 0) {
      return {
        saleDate: fallbackSaleDate,
        guestName: null as string | null,
        owner: null as string | null,
        workPerformer: null as string | null,
        totalExGst: null as number | null,
      }
    }
    const first = rows[0]
    const guestName = titleCaseGuestName(first.customer_name)
    const owner =
      trimOrNull(first.commission_owner_candidate_name) ?? null
    const workPerformer =
      trimOrNull(first.staff_work_display_name) ??
      trimOrNull(first.staff_work_full_name) ??
      trimOrNull(first.staff_work_name) ??
      null
    let total = 0
    let hasAny = false
    for (const r of rows) {
      const n =
        typeof r.price_ex_gst === 'number'
          ? r.price_ex_gst
          : r.price_ex_gst == null
            ? NaN
            : Number(r.price_ex_gst)
      if (Number.isFinite(n)) {
        total += n
        hasAny = true
      }
    }
    return {
      saleDate: first.sale_date ?? fallbackSaleDate,
      guestName,
      owner,
      workPerformer,
      totalExGst: hasAny ? total : null,
    }
  }, [rows, fallbackSaleDate])

  if (!invoice) {
    return (
      <EmptyState
        title="No invoice selected"
        description="There is no invoice to display."
        testId="invoice-detail-empty"
      />
    )
  }
  if (isLoading) {
    return <LoadingState testId="invoice-detail-loading" />
  }
  if (isError) {
    const detail = queryErrorDetail(error)
    return (
      <ErrorState
        title="Could not load invoice"
        message={detail.message}
        error={detail.err}
        onRetry={refetch}
        testId="invoice-detail-error"
      />
    )
  }

  return (
    <div className="flex flex-col gap-4">
      <dl className="grid grid-cols-1 gap-x-4 gap-y-2 text-sm sm:grid-cols-2">
        <SummaryRow label="Date" value={formatShortDate(summary.saleDate)} />
        <SummaryRow label="Guest" value={summary.guestName ?? '—'} />
        <SummaryRow label="Owner" value={summary.owner ?? '—'} />
        <SummaryRow
          label="Work performed by"
          value={summary.workPerformer ?? '—'}
        />
      </dl>

      {rows.length === 0 ? (
        <EmptyState
          title="No invoice lines"
          description="No sale lines were returned for this invoice."
          testId="invoice-detail-empty-rows"
        />
      ) : (
        <div className="-mx-5 overflow-x-auto sm:mx-0">
          <table className="w-full min-w-[560px] text-left text-sm">
            <thead className="border-b border-slate-200 text-[11px] uppercase tracking-wide text-slate-500">
              <tr>
                <th scope="col" className="px-3 py-2 font-semibold">
                  Product
                </th>
                <th scope="col" className="px-3 py-2 font-semibold">
                  Owner
                </th>
                <th scope="col" className="px-3 py-2 font-semibold">
                  Work performed by
                </th>
                <th
                  scope="col"
                  className="px-3 py-2 text-right font-semibold"
                >
                  Sales ex GST
                </th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r, idx) => {
                const product = trimOrNull(r.product_service_name) ?? '—'
                const owner =
                  trimOrNull(r.commission_owner_candidate_name) ?? '—'
                const worker =
                  trimOrNull(r.staff_work_display_name) ??
                  trimOrNull(r.staff_work_full_name) ??
                  trimOrNull(r.staff_work_name) ??
                  '—'
                return (
                  <tr
                    key={idx}
                    className="border-b border-slate-100 align-top"
                  >
                    <td className="px-3 py-2 text-slate-900">{product}</td>
                    <td className="px-3 py-2 text-slate-700">{owner}</td>
                    <td className="px-3 py-2 text-slate-700">{worker}</td>
                    <td className="px-3 py-2 text-right tabular-nums text-slate-800">
                      {formatNzd(r.price_ex_gst)}
                    </td>
                  </tr>
                )
              })}
              {summary.totalExGst != null ? (
                <tr className="border-t border-slate-200 bg-slate-50">
                  <td
                    colSpan={3}
                    className="px-3 py-2 text-right text-xs font-semibold uppercase tracking-wide text-slate-600"
                  >
                    Total ex GST
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums font-semibold text-slate-900">
                    {formatNzd(summary.totalExGst)}
                  </td>
                </tr>
              ) : null}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}

function SummaryRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col gap-0.5">
      <dt className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">
        {label}
      </dt>
      <dd className="text-sm text-slate-800">{value}</dd>
    </div>
  )
}

function trimOrNull(v: string | null | undefined): string | null {
  if (v == null) return null
  const t = v.trim()
  return t.length > 0 ? t : null
}
