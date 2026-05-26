import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'

import { ConfirmDialog } from '@/components/feedback/ConfirmDialog'
import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { TableScrollArea } from '@/components/ui/TableScrollArea'
import { InvoiceDetailModal } from '@/features/kpi/components/InvoiceDetailModal'
import {
  useCanViewPage,
  useIsPageViewOnly,
} from '@/features/access/pageAccess'
import { StaffLocationNavBadge } from '@/features/admin/components/StaffLocationNavBadge'
import { useBusinessSettings } from '@/features/admin/hooks/useBusinessSettings'
import {
  useContractorInvoiceBatch,
  useContractorInvoicePayWeeks,
  useContractorInvoicePreview,
  useContractorVoidedInvoicesForWeek,
} from '@/features/admin/hooks/useContractorInvoices'
import { businessSettingsMissingRequiredFields } from '@/features/admin/types/businessSettings'
import {
  batchRowLocationBadges,
  BUSINESS_SETTINGS_FIELD_LABELS,
  CONTRACTOR_FIELD_LABELS,
  contractorPersonAndCompany,
  type ContractorInvoiceBatchRow,
  type ContractorInvoicePreviewLineRow,
  type ContractorVoidedInvoiceRow,
} from '@/features/admin/types/contractorInvoice'
import { rpcCreateContractorInvoice } from '@/lib/contractorInvoicesApi'
import {
  formatCommissionRateNearestHalfPercent,
  formatNzd,
  formatShortDate,
} from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'

function asNumber(v: unknown): number {
  if (v == null || v === '') return 0
  const n = typeof v === 'number' ? v : Number(v)
  return Number.isFinite(n) ? n : 0
}

/**
 * Identifier tuple consumed by the KPI {@link InvoiceDetailModal}. Built
 * from each contractor-invoice line (preview or saved) so clicking the
 * source invoice number on this page opens the same per-line breakdown
 * the KPI drilldown uses, without routing away from Contractor Invoices.
 */
type SourceInvoiceRef = {
  invoice: string
  locationId: string | null
  saleDate: string | null
}

/**
 * Visual style for the clickable source-invoice number in the *preview*
 * table. Mirrors the KPI drilldown's invoice-number button so both
 * surfaces feel consistent. The saved-invoice print view uses a
 * different (invisible) button style — see {@link ContractorInvoicePrintView}.
 */
const SOURCE_INVOICE_BTN_CLASS =
  'cursor-pointer font-medium text-violet-700 hover:text-violet-900 focus:outline-none focus-visible:underline'

function thClass(): string {
  return 'whitespace-nowrap border-b border-slate-200 px-3 py-2 text-left text-[11px] font-semibold uppercase tracking-wide text-slate-600'
}
function thRightClass(): string {
  return 'whitespace-nowrap border-b border-slate-200 px-3 py-2 text-right text-[11px] font-semibold uppercase tracking-wide text-slate-600'
}
function tdClass(): string {
  return 'whitespace-nowrap border-b border-slate-100 px-3 py-2 text-sm text-slate-800'
}
function tdRightClass(): string {
  return 'whitespace-nowrap border-b border-slate-100 px-3 py-2 text-right text-sm tabular-nums text-slate-800'
}

function StatusBadge({ row }: { row: ContractorInvoiceBatchRow }) {
  if (!row.active_invoice_id) {
    return (
      <span className="inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 text-[11px] font-medium text-slate-700">
        Not invoiced
      </span>
    )
  }
  return (
    <span className="inline-flex items-center rounded-full bg-emerald-50 px-2 py-0.5 text-[11px] font-medium text-emerald-800">
      Created
    </span>
  )
}

function LocationBadges({ row }: { row: ContractorInvoiceBatchRow }) {
  const badges = batchRowLocationBadges(row)
  if (badges.length === 0) {
    return <StaffLocationNavBadge letter={null} />
  }
  return (
    <span className="inline-flex items-center gap-0.5">
      {badges.map((b) => (
        <StaffLocationNavBadge key={b} letter={b} />
      ))}
    </span>
  )
}

function SetupBadge({ count }: { count: number }) {
  if (count === 0) return null
  return (
    <span
      className="ml-2 inline-flex items-center rounded-full bg-amber-100 px-1.5 py-0.5 text-[10px] font-medium text-amber-900"
      title={`${count} required field${count === 1 ? '' : 's'} missing`}
    >
      Setup incomplete
    </span>
  )
}

// ---------------------------------------------------------------------------
// Preview Modal
// ---------------------------------------------------------------------------

type PreviewState = {
  row: ContractorInvoiceBatchRow
}

function PreviewModal(props: {
  state: PreviewState
  payWeekStart: string
  onClose: () => void
  onCreated: (invoiceId: string) => void
  canCreate: boolean
  buyerMissingFields: string[]
  onOpenInvoice: (ref: SourceInvoiceRef) => void
  /**
   * When true the modal stops handling Escape key events. Used while a
   * nested InvoiceDetailModal is open at the page level so Esc only
   * closes the top-most popup instead of both modals at once.
   */
  suppressEscape: boolean
}) {
  const {
    state,
    payWeekStart,
    onClose,
    onCreated,
    canCreate,
    buyerMissingFields,
    onOpenInvoice,
    suppressEscape,
  } = props
  const queryClient = useQueryClient()
  const [internalNote, setInternalNote] = useState('')
  const [confirmOpen, setConfirmOpen] = useState(false)
  const [errMsg, setErrMsg] = useState<string | null>(null)

  const preview = useContractorInvoicePreview({
    payWeekStart,
    staffMemberId: state.row.staff_member_id,
  })

  const createMut = useMutation({
    mutationFn: async () => {
      return await rpcCreateContractorInvoice({
        payWeekStart,
        staffMemberId: state.row.staff_member_id,
        internalNote: internalNote.trim() || null,
      })
    },
    onSuccess: async (res) => {
      await queryClient.invalidateQueries({ queryKey: ['contractor-invoice-batch'] })
      onCreated(res.id)
    },
    onError: (err) => {
      setErrMsg(queryErrorDetail(err).err?.message ?? 'Create failed.')
    },
  })

  useEffect(() => {
    if (suppressEscape) return
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [onClose, suppressEscape])

  const totals = useMemo(() => {
    const lines: ContractorInvoicePreviewLineRow[] = preview.data ?? []
    const sub = lines.reduce(
      (acc, l) => acc + asNumber(l.contractor_amount_ex_gst),
      0,
    )
    const gst = state.row.contractor_gst_registered ? sub * 0.15 : 0
    return {
      lineCount: lines.length,
      subtotal: sub,
      gst,
      total: sub + gst,
    }
  }, [preview.data, state.row.contractor_gst_registered])

  const showLocationColumn = useMemo(() => {
    const lines = preview.data ?? []
    const seen = new Set<string>()
    for (const l of lines) {
      const id = String(l.location_id ?? '').trim()
      if (id !== '') seen.add(id)
    }
    return seen.size > 1
  }, [preview.data])

  const setupMissing = (state.row.setup_missing_fields ?? []) as string[]
  const blocked =
    !canCreate ||
    setupMissing.length > 0 ||
    buyerMissingFields.length > 0 ||
    totals.subtotal <= 0
  const isZero = totals.lineCount === 0 || totals.subtotal <= 0

  const displayName = contractorPersonAndCompany({
    contractor_full_name: state.row.contractor_full_name,
    contractor_company_name: state.row.contractor_company_name,
  })

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      role="dialog"
      aria-modal="true"
      onClick={onClose}
    >
      <div
        className="flex max-h-[90vh] w-full max-w-5xl flex-col overflow-hidden rounded-lg border border-slate-200 bg-white shadow-xl"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex items-start justify-between gap-3 border-b border-slate-200 px-5 py-3">
          <div>
            <h2 className="text-base font-semibold text-slate-900">
              Preview invoice — {displayName}
            </h2>
            <p className="mt-0.5 text-xs text-slate-600">
              Pay week {formatShortDate(payWeekStart)} – {formatShortDate(state.row.pay_week_end)}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-md border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
          >
            Close
          </button>
        </header>

        <div className="flex-1 overflow-y-auto px-5 py-4">
          <div className="mb-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900">
            <strong>Preview only.</strong> These amounts are based on current Weekly Payroll data
            and are not locked until the invoice is created.
          </div>

          {setupMissing.length > 0 ? (
            <div className="mb-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-800">
              <p className="font-semibold">Contractor setup incomplete:</p>
              <p className="mt-1">
                Missing —{' '}
                {setupMissing
                  .map((k) => CONTRACTOR_FIELD_LABELS[k] ?? k)
                  .join(', ')}
                .
              </p>
              <p className="mt-1">
                <Link
                  to="/app/admin/staff"
                  className="font-medium text-rose-900 underline underline-offset-2 hover:text-rose-700"
                >
                  Fix in Staff Admin →
                </Link>
              </p>
            </div>
          ) : null}

          {buyerMissingFields.length > 0 ? (
            <div className="mb-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-800">
              <p className="font-semibold">Business settings incomplete:</p>
              <p className="mt-1">
                Missing —{' '}
                {buyerMissingFields
                  .map((k) => BUSINESS_SETTINGS_FIELD_LABELS[
                    k as keyof typeof BUSINESS_SETTINGS_FIELD_LABELS
                  ] ?? k)
                  .join(', ')}
                .
              </p>
              <p className="mt-1">
                <Link
                  to="/app/admin/business-settings"
                  className="font-medium text-rose-900 underline underline-offset-2 hover:text-rose-700"
                >
                  Fix in Business Settings →
                </Link>
              </p>
            </div>
          ) : null}

          {preview.isLoading || preview.isPending ? (
            <LoadingState message="Loading preview…" />
          ) : preview.isError ? (
            <ErrorState
              title="Could not load preview"
              error={preview.error}
              onRetry={() => void preview.refetch()}
            />
          ) : isZero ? (
            <EmptyState
              title="No payable lines for this week"
              description="This contractor has no payable Weekly Payroll lines for the selected pay week, so no invoice can be created."
            />
          ) : (
            <>
              {/*
                Plain `w-full` table (no TableScrollArea) so the modal can
                scroll vertically only — the parent body already owns
                `overflow-y-auto`. `table-auto` lets the Client cell wrap
                with `break-words` while money/rate cells stay nowrap, so
                the row width never exceeds the modal width.
              */}
              <div className="overflow-hidden rounded-md border border-slate-200">
                <table className="w-full table-auto border-collapse text-[13px]">
                  <thead className="bg-slate-50">
                    <tr>
                      <th className="whitespace-nowrap border-b border-slate-200 px-2 py-1.5 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-600">
                        Date
                      </th>
                      <th className="whitespace-nowrap border-b border-slate-200 px-2 py-1.5 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-600">
                        Invoice
                      </th>
                      <th className="border-b border-slate-200 px-2 py-1.5 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-600">
                        Client
                      </th>
                      {showLocationColumn ? (
                        <th className="whitespace-nowrap border-b border-slate-200 px-2 py-1.5 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-600">
                          Location
                        </th>
                      ) : null}
                      <th className="whitespace-nowrap border-b border-slate-200 px-2 py-1.5 text-right text-[10px] font-semibold uppercase tracking-wide text-slate-600">
                        Sale (ex GST)
                      </th>
                      <th className="whitespace-nowrap border-b border-slate-200 px-2 py-1.5 text-right text-[10px] font-semibold uppercase tracking-wide text-slate-600">
                        Rate
                      </th>
                      <th className="whitespace-nowrap border-b border-slate-200 px-2 py-1.5 text-right text-[10px] font-semibold uppercase tracking-wide text-slate-600">
                        Contractor (ex GST)
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    {(preview.data ?? []).map((l) => (
                      <tr key={l.source_invoice_number} className="hover:bg-slate-50">
                        <td className="whitespace-nowrap border-b border-slate-100 px-2 py-1.5 align-top text-slate-800">
                          {formatShortDate(l.sale_date)}
                        </td>
                        <td className="whitespace-nowrap border-b border-slate-100 px-2 py-1.5 align-top text-slate-800">
                          <button
                            type="button"
                            className={SOURCE_INVOICE_BTN_CLASS}
                            onClick={() =>
                              onOpenInvoice({
                                invoice: l.source_invoice_number,
                                locationId: l.location_id,
                                saleDate: l.sale_date,
                              })
                            }
                            aria-label={`View invoice detail for ${l.source_invoice_number}`}
                          >
                            {l.source_invoice_number}
                          </button>
                        </td>
                        <td className="break-words border-b border-slate-100 px-2 py-1.5 align-top text-slate-800">
                          {l.customer_name ?? '—'}
                        </td>
                        {showLocationColumn ? (
                          <td className="whitespace-nowrap border-b border-slate-100 px-2 py-1.5 align-top text-slate-600">
                            {l.location_name ?? '—'}
                          </td>
                        ) : null}
                        <td className="whitespace-nowrap border-b border-slate-100 px-2 py-1.5 text-right align-top tabular-nums text-slate-800">
                          {formatNzd(l.client_invoice_amount_ex_gst)}
                        </td>
                        <td className="whitespace-nowrap border-b border-slate-100 px-2 py-1.5 text-right align-top tabular-nums text-slate-800">
                          {formatCommissionRateNearestHalfPercent(l.commission_percentage)}
                        </td>
                        <td className="whitespace-nowrap border-b border-slate-100 px-2 py-1.5 text-right align-top tabular-nums text-slate-800">
                          {formatNzd(l.contractor_amount_ex_gst)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>

              <div className="mt-4 flex justify-end">
                <dl className="grid w-full max-w-xs grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-sm">
                  <dt className="text-slate-600">Subtotal (ex GST)</dt>
                  <dd className="text-right tabular-nums">{formatNzd(totals.subtotal)}</dd>
                  <dt className="text-slate-600">
                    GST {state.row.contractor_gst_registered ? '(15%)' : '(0%)'}
                  </dt>
                  <dd className="text-right tabular-nums">{formatNzd(totals.gst)}</dd>
                  <dt className="border-t border-slate-200 pt-1 font-semibold text-slate-900">
                    Total
                  </dt>
                  <dd className="border-t border-slate-200 pt-1 text-right text-base font-semibold tabular-nums text-slate-900">
                    {formatNzd(totals.total)}
                  </dd>
                </dl>
              </div>

              {canCreate ? (
                <div className="mt-5">
                  <label
                    htmlFor="preview-note"
                    className="block text-sm font-medium text-slate-700"
                  >
                    Internal note (optional, not shown on PDF)
                  </label>
                  <textarea
                    id="preview-note"
                    value={internalNote}
                    onChange={(e) => setInternalNote(e.target.value)}
                    rows={2}
                    className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                  />
                </div>
              ) : null}

              {errMsg ? (
                <div
                  className="mt-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-800"
                  role="status"
                >
                  {errMsg}
                </div>
              ) : null}
            </>
          )}
        </div>

        <footer className="flex items-center justify-end gap-2 border-t border-slate-200 px-5 py-3">
          <button
            type="button"
            onClick={onClose}
            className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Close
          </button>
          {canCreate ? (
            <button
              type="button"
              disabled={blocked || createMut.isPending}
              onClick={() => setConfirmOpen(true)}
              className="rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700 disabled:opacity-50"
            >
              {createMut.isPending ? 'Creating…' : 'Create invoice'}
            </button>
          ) : null}
        </footer>
      </div>

      <ConfirmDialog
        open={confirmOpen}
        title={`Create invoice for ${displayName}?`}
        description={
          'This will save a locked snapshot of the current Weekly Payroll data. ' +
          'If changes are needed later, this invoice must be voided.'
        }
        confirmLabel="Create"
        tone="primary"
        onConfirm={() => createMut.mutate()}
        onClose={() => setConfirmOpen(false)}
      />
    </div>
  )
}

// ---------------------------------------------------------------------------
// Page
// ---------------------------------------------------------------------------

export function AdminContractorInvoicesPage() {
  const [search, setSearch] = useSearchParams()
  const navigate = useNavigate()
  const viewOnly = useIsPageViewOnly('contractor_invoices')
  const canViewBusinessSettings = useCanViewPage('business_settings')

  const weeksQuery = useContractorInvoicePayWeeks()
  const businessQuery = useBusinessSettings()

  const payWeekFromUrl = search.get('pay_week') ?? undefined
  const includeZero = search.get('include_zero') === '1'
  const showVoided = search.get('show_voided') === '1'

  const defaultWeek = useMemo(() => {
    const rows = weeksQuery.data ?? []
    if (rows.length === 0) return undefined
    return rows[0].pay_week_start
  }, [weeksQuery.data])

  const payWeek = payWeekFromUrl ?? defaultWeek

  useEffect(() => {
    if (!payWeekFromUrl && defaultWeek) {
      const next = new URLSearchParams(search)
      next.set('pay_week', defaultWeek)
      setSearch(next, { replace: true })
    }
  }, [payWeekFromUrl, defaultWeek, search, setSearch])

  const batchQuery = useContractorInvoiceBatch({
    payWeekStart: payWeek,
    includeZeroContractors: includeZero,
  })

  const voidedQuery = useContractorVoidedInvoicesForWeek({
    payWeekStart: payWeek,
    enabled: showVoided,
  })

  const buyerMissing = useMemo(
    () =>
      businessSettingsMissingRequiredFields(businessQuery.data ?? null).map(
        (k) => String(k),
      ),
    [businessQuery.data],
  )

  const [previewState, setPreviewState] = useState<PreviewState | null>(null)
  const [invoiceDetailRef, setInvoiceDetailRef] = useState<
    SourceInvoiceRef | null
  >(null)

  const setPayWeek = (next: string) => {
    const params = new URLSearchParams(search)
    params.set('pay_week', next)
    setSearch(params, { replace: true })
  }
  const setIncludeZero = (next: boolean) => {
    const params = new URLSearchParams(search)
    if (next) params.set('include_zero', '1')
    else params.delete('include_zero')
    setSearch(params, { replace: true })
  }
  const setShowVoided = (next: boolean) => {
    const params = new URLSearchParams(search)
    if (next) params.set('show_voided', '1')
    else params.delete('show_voided')
    setSearch(params, { replace: true })
  }

  const rows: ContractorInvoiceBatchRow[] = batchQuery.data ?? []
  const voidedRows: ContractorVoidedInvoiceRow[] = voidedQuery.data ?? []

  return (
    <div
      className="w-full min-w-0 py-4 sm:py-6"
      data-testid="admin-contractor-invoices-page"
    >
      <PageHeader
        title="Contractor invoices"
        description={
          'Buyer-created tax invoices for contractor staff. Source of truth is Weekly Payroll.\n' +
          'Each saved invoice is a locked snapshot — to change one, void it.'
        }
      />

      {buyerMissing.length > 0 && canViewBusinessSettings ? (
        <div
          className="mb-4 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900"
          role="status"
        >
          <strong className="font-semibold">Business settings incomplete:</strong>{' '}
          Missing —{' '}
          {buyerMissing
            .map((k) => BUSINESS_SETTINGS_FIELD_LABELS[
              k as keyof typeof BUSINESS_SETTINGS_FIELD_LABELS
            ] ?? k)
            .join(', ')}
          .{' '}
          <Link
            to="/app/admin/business-settings"
            className="font-medium underline underline-offset-2 hover:text-amber-700"
          >
            Fix in Business Settings →
          </Link>
        </div>
      ) : null}

      <div className="mb-3 flex flex-wrap items-end gap-3">
        <div>
          <label
            className="block text-xs font-medium text-slate-600"
            htmlFor="ci-pay-week"
          >
            Pay week
          </label>
          <select
            id="ci-pay-week"
            value={payWeek ?? ''}
            onChange={(e) => setPayWeek(e.target.value)}
            disabled={weeksQuery.isLoading || (weeksQuery.data ?? []).length === 0}
            className="mt-1 min-w-[14rem] rounded-md border border-slate-300 px-2 py-1.5 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
          >
            {(weeksQuery.data ?? []).map((w) => (
              <option key={w.pay_week_start} value={w.pay_week_start}>
                {formatShortDate(w.pay_week_start)} – {formatShortDate(w.pay_week_end)}
              </option>
            ))}
          </select>
        </div>
        <label className="inline-flex cursor-pointer items-center gap-2 pb-1.5 text-sm text-slate-700">
          <input
            type="checkbox"
            checked={includeZero}
            onChange={(e) => setIncludeZero(e.target.checked)}
            className="rounded border-slate-300"
          />
          Show contractors with no payable lines
        </label>
        <label className="inline-flex cursor-pointer items-center gap-2 pb-1.5 text-sm text-slate-700">
          <input
            type="checkbox"
            checked={showVoided}
            onChange={(e) => setShowVoided(e.target.checked)}
            className="rounded border-slate-300"
          />
          Show voided invoices
        </label>
      </div>

      {weeksQuery.isLoading || batchQuery.isLoading ? (
        <LoadingState message="Loading contractor invoices…" />
      ) : weeksQuery.isError ? (
        <ErrorState
          title="Could not load pay weeks"
          error={weeksQuery.error}
          onRetry={() => void weeksQuery.refetch()}
        />
      ) : businessQuery.isError ? (
        <ErrorState
          title="Could not load business settings"
          error={businessQuery.error}
          onRetry={() => void businessQuery.refetch()}
        />
      ) : batchQuery.isError ? (
        <ErrorState
          title="Could not load contractor invoices"
          error={batchQuery.error}
          onRetry={() => void batchQuery.refetch()}
        />
      ) : !payWeek ? (
        <EmptyState
          title="No pay weeks yet"
          description="No payroll data is available for contractor invoicing."
        />
      ) : rows.length === 0 ? (
        <EmptyState
          title={includeZero ? 'No active contractors' : 'No payable contractors this week'}
          description={
            includeZero
              ? 'No contractor staff are configured.'
              : 'No contractor has payable lines for this pay week. Toggle on to see all active contractors.'
          }
        />
      ) : (
        <div className="rounded-lg border border-slate-200 bg-white shadow-sm">
          <TableScrollArea>
            <table className="min-w-full border-collapse text-sm">
              <thead>
                <tr>
                  <th className={thClass()}>Contractor</th>
                  <th className={thClass()}>GST</th>
                  <th className={thRightClass()}>Subtotal</th>
                  <th className={thRightClass()}>GST</th>
                  <th className={thRightClass()}>Total</th>
                  <th className={thClass()}>Status</th>
                  <th className={thClass()}>Invoice no.</th>
                  <th className={thClass()}>Actions</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const setupCount = (r.setup_missing_fields ?? []).length
                  const subtotal = asNumber(r.payable_subtotal_ex_gst)
                  const hasPayable = subtotal > 0
                  const blockedByBuyer = buyerMissing.length > 0
                  const canCreate =
                    !viewOnly &&
                    hasPayable &&
                    setupCount === 0 &&
                    !blockedByBuyer &&
                    !r.active_invoice_id
                  const displayName = contractorPersonAndCompany({
                    contractor_full_name: r.contractor_full_name,
                    contractor_company_name: r.contractor_company_name,
                  })
                  return (
                    <tr key={r.staff_member_id} className="hover:bg-slate-50">
                      <td className={tdClass()}>
                        <div className="flex items-center gap-1.5">
                          <LocationBadges row={r} />
                          <span>{displayName}</span>
                          <SetupBadge count={setupCount} />
                          {!r.contractor_is_active ? (
                            <span className="ml-2 inline-flex items-center rounded-full bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-600">
                              Inactive
                            </span>
                          ) : null}
                        </div>
                      </td>
                      <td className={tdClass()}>
                        {r.contractor_gst_registered === true
                          ? 'Registered'
                          : r.contractor_gst_registered === false
                            ? 'Not registered'
                            : '—'}
                      </td>
                      <td className={tdRightClass()}>
                        {formatNzd(r.payable_subtotal_ex_gst)}
                      </td>
                      <td className={tdRightClass()}>
                        {formatNzd(r.payable_gst_amount)}
                      </td>
                      <td className={tdRightClass()}>
                        {formatNzd(r.payable_total_inc_gst)}
                      </td>
                      <td className={tdClass()}>
                        <StatusBadge row={r} />
                      </td>
                      <td className={tdClass()}>
                        {r.active_invoice_number ?? '—'}
                      </td>
                      <td className={tdClass()}>
                        <div className="flex flex-wrap gap-2">
                          {r.active_invoice_id ? (
                            <Link
                              to={`/app/admin/contractor-invoices/${r.active_invoice_id}`}
                              className="rounded-md border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                            >
                              View
                            </Link>
                          ) : (
                            <>
                              <button
                                type="button"
                                onClick={() => setPreviewState({ row: r })}
                                className="rounded-md border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                              >
                                Preview
                              </button>
                              {!viewOnly ? (
                                <button
                                  type="button"
                                  disabled={!canCreate}
                                  onClick={() => setPreviewState({ row: r })}
                                  className="rounded-md bg-violet-600 px-2 py-1 text-xs font-medium text-white shadow-sm hover:bg-violet-700 disabled:opacity-50"
                                  title={
                                    canCreate
                                      ? 'Create invoice'
                                      : 'Cannot create — see setup warnings'
                                  }
                                >
                                  Create
                                </button>
                              ) : null}
                            </>
                          )}
                        </div>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </TableScrollArea>
        </div>
      )}

      {showVoided && payWeek ? (
        <VoidedInvoicesSection
          isLoading={voidedQuery.isLoading || voidedQuery.isPending}
          isError={voidedQuery.isError}
          error={voidedQuery.error}
          rows={voidedRows}
          onRetry={() => void voidedQuery.refetch()}
        />
      ) : null}

      {previewState ? (
        <PreviewModal
          state={previewState}
          payWeekStart={payWeek!}
          onClose={() => setPreviewState(null)}
          onCreated={(id) => {
            setPreviewState(null)
            navigate(`/app/admin/contractor-invoices/${id}`)
          }}
          canCreate={!viewOnly}
          buyerMissingFields={buyerMissing}
          onOpenInvoice={setInvoiceDetailRef}
          suppressEscape={invoiceDetailRef !== null}
        />
      ) : null}

      {/*
        Reuse the KPI drilldown InvoiceDetailModal so the per-line
        breakdown looks/works identically here. Rendered as a sibling so
        it stacks above the PreviewModal when both are open.
      */}
      <InvoiceDetailModal
        open={invoiceDetailRef !== null}
        onClose={() => setInvoiceDetailRef(null)}
        invoice={invoiceDetailRef?.invoice ?? null}
        locationId={invoiceDetailRef?.locationId ?? null}
        saleDate={invoiceDetailRef?.saleDate ?? null}
      />
    </div>
  )
}

// ---------------------------------------------------------------------------
// Voided invoices for the selected pay week
// ---------------------------------------------------------------------------

function VoidedInvoicesSection(props: {
  isLoading: boolean
  isError: boolean
  error: Error | null
  rows: ContractorVoidedInvoiceRow[]
  onRetry: () => void
}) {
  const { isLoading, isError, error, rows, onRetry } = props

  return (
    <section className="mt-6">
      <header className="mb-2 flex items-baseline justify-between">
        <h2 className="text-sm font-semibold text-slate-800">
          Voided invoices for this pay week
        </h2>
        <p className="text-xs text-slate-500">
          Audit history — voided invoices are read-only.
        </p>
      </header>

      {isLoading ? (
        <LoadingState message="Loading voided invoices…" />
      ) : isError ? (
        <ErrorState
          title="Could not load voided invoices"
          error={error}
          onRetry={onRetry}
        />
      ) : rows.length === 0 ? (
        <div className="rounded-md border border-dashed border-slate-200 bg-slate-50 px-3 py-4 text-center text-xs text-slate-500">
          No voided invoices for this pay week.
        </div>
      ) : (
        <div className="rounded-lg border border-slate-200 bg-white shadow-sm">
          <TableScrollArea>
            <table className="min-w-full border-collapse text-sm">
              <thead>
                <tr>
                  <th className={thClass()}>Contractor</th>
                  <th className={thClass()}>GST</th>
                  <th className={thRightClass()}>Subtotal</th>
                  <th className={thRightClass()}>GST</th>
                  <th className={thRightClass()}>Total</th>
                  <th className={thClass()}>Status</th>
                  <th className={thClass()}>Invoice no.</th>
                  <th className={thClass()}>Voided</th>
                  <th className={thClass()}>Actions</th>
                </tr>
              </thead>
              <tbody>
                {rows.map((r) => {
                  const displayName = contractorPersonAndCompany({
                    contractor_full_name: r.contractor_full_name,
                    contractor_company_name: r.contractor_company_name,
                  })
                  const code = (r.contractor_primary_location_code ?? '')
                    .trim()
                    .toUpperCase()
                  const letter: 'O' | 'T' | null =
                    code === 'ORE' ? 'O' : code === 'TAK' ? 'T' : null
                  return (
                    <tr key={r.invoice_id} className="hover:bg-slate-50">
                      <td className={tdClass()}>
                        <div className="flex items-center gap-1.5">
                          <StaffLocationNavBadge letter={letter} />
                          <span>{displayName}</span>
                          {!r.contractor_is_active ? (
                            <span className="ml-2 inline-flex items-center rounded-full bg-slate-100 px-1.5 py-0.5 text-[10px] font-medium text-slate-600">
                              Inactive
                            </span>
                          ) : null}
                        </div>
                      </td>
                      <td className={tdClass()}>
                        {r.contractor_gst_registered === true
                          ? 'Registered'
                          : r.contractor_gst_registered === false
                            ? 'Not registered'
                            : '—'}
                      </td>
                      <td className={tdRightClass()}>
                        {formatNzd(r.subtotal_ex_gst)}
                      </td>
                      <td className={tdRightClass()}>
                        {formatNzd(r.gst_amount)}
                      </td>
                      <td className={tdRightClass()}>
                        {formatNzd(r.total_inc_gst)}
                      </td>
                      <td className={tdClass()}>
                        <span
                          className="inline-flex items-center rounded-full bg-rose-50 px-2 py-0.5 text-[11px] font-medium text-rose-800"
                          title={r.void_reason ?? undefined}
                        >
                          Voided
                        </span>
                      </td>
                      <td className={tdClass()}>{r.invoice_number}</td>
                      <td className={tdClass()}>
                        {r.voided_at ? formatShortDate(r.voided_at) : '—'}
                        {r.replaced_by_invoice_number ? (
                          <span className="ml-2 text-xs text-slate-500">
                            → {r.replaced_by_invoice_number}
                          </span>
                        ) : null}
                      </td>
                      <td className={tdClass()}>
                        <Link
                          to={`/app/admin/contractor-invoices/${r.invoice_id}`}
                          className="rounded-md border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                        >
                          View
                        </Link>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </TableScrollArea>
        </div>
      )}
    </section>
  )
}
