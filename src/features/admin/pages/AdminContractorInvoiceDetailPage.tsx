import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'

import { ConfirmDialog } from '@/components/feedback/ConfirmDialog'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useIsPageViewOnly } from '@/features/access/pageAccess'
import { ContractorInvoicePrintView } from '@/features/admin/components/ContractorInvoicePrintView'
import { useContractorInvoice } from '@/features/admin/hooks/useContractorInvoices'
import { InvoiceDetailModal } from '@/features/kpi/components/InvoiceDetailModal'
import { rpcVoidContractorInvoice } from '@/lib/contractorInvoicesApi'
import { formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'

// NOTE: The "Void & replace" UI is intentionally hidden for now. Only
// voiding is exposed at this stage; a future replacement workflow will
// be designed separately. The backend RPC (`rpcReplaceContractorInvoice`
// + `replace_contractor_invoice` SQL function) is left intact and can be
// re-imported when the UI is re-enabled.

type SourceInvoiceRef = {
  invoice: string
  locationId: string | null
  saleDate: string | null
}

export function AdminContractorInvoiceDetailPage() {
  const { invoiceId } = useParams<{ invoiceId: string }>()
  const queryClient = useQueryClient()
  const viewOnly = useIsPageViewOnly('contractor_invoices')

  const { data, isLoading, isError, error, refetch } = useContractorInvoice(invoiceId)

  const [voidOpen, setVoidOpen] = useState(false)
  const [voidReason, setVoidReason] = useState('')
  const [confirmVoid, setConfirmVoid] = useState(false)
  const [feedback, setFeedback] = useState<
    | { kind: 'success'; message: string }
    | { kind: 'error'; message: string }
    | null
  >(null)
  const [invoiceDetailRef, setInvoiceDetailRef] = useState<
    SourceInvoiceRef | null
  >(null)
  const [emailOpen, setEmailOpen] = useState(false)
  const [emailCopied, setEmailCopied] = useState(false)

  const voidMut = useMutation({
    mutationFn: async () => {
      if (!invoiceId) return
      await rpcVoidContractorInvoice({
        invoiceId,
        voidReason: voidReason.trim(),
      })
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['contractor-invoice', invoiceId] })
      await queryClient.invalidateQueries({ queryKey: ['contractor-invoice-batch'] })
      setVoidOpen(false)
      setVoidReason('')
      setFeedback({ kind: 'success', message: 'Invoice voided.' })
    },
    onError: (err) => {
      setFeedback({
        kind: 'error',
        message: queryErrorDetail(err).err?.message ?? 'Void failed.',
      })
    },
  })

  const headerNumber = useMemo(() => data?.header.invoice_number ?? '', [data])

  /*
    Set the browser document title to the invoice number so the native
    "Print / Save as PDF" dialog defaults its filename to e.g.
    "JF-26-0517.pdf" instead of the app-wide "Oscar & Co Staff App.pdf".
    The effect captures the previous title and restores it on unmount /
    invoice change, so navigating back to the batch (or to another
    invoice) doesn't leave a stale invoice number in the tab title.
  */
  useEffect(() => {
    if (!headerNumber) return
    const previous = document.title
    document.title = headerNumber
    return () => {
      document.title = previous
    }
  }, [headerNumber])

  /*
    Default subject + message body for the "Email to staff member"
    helper. mailto: cannot attach files (browser security), so the user
    is reminded to attach the saved PDF manually after Print / Save as
    PDF. Built from the saved invoice snapshot so the values match what
    actually printed (no live recomputation).
  */
  const emailDraft = useMemo(() => {
    const to = (data?.header.contractor_email ?? '').trim()
    const fullName = (data?.header.contractor_full_name ?? '').trim()
    const firstName =
      fullName.split(/\s+/).find((s) => s.length > 0) ?? 'there'
    const number = data?.header.invoice_number ?? ''
    const subject = number
      ? `Buyer Created Tax Invoice ${number}`
      : 'Buyer Created Tax Invoice'
    const weekStart = data?.header.pay_week_start
      ? formatShortDate(data.header.pay_week_start)
      : '—'
    const weekEnd = data?.header.pay_week_end
      ? formatShortDate(data.header.pay_week_end)
      : '—'
    const body =
      `Hi ${firstName},\n\n` +
      `Please find attached your buyer-created tax invoice for the pay week ${weekStart} to ${weekEnd}.\n\n` +
      `Thanks,\n` +
      `Oscar & Co`
    return { to, subject, body }
  }, [data])

  const hasContractorEmail = emailDraft.to.length > 0
  const mailtoHref = hasContractorEmail
    ? `mailto:${encodeURIComponent(emailDraft.to)}` +
      `?subject=${encodeURIComponent(emailDraft.subject)}` +
      `&body=${encodeURIComponent(emailDraft.body)}`
    : ''

  async function copyEmailDraft() {
    const payload = `Subject: ${emailDraft.subject}\n\n${emailDraft.body}`
    try {
      await navigator.clipboard.writeText(payload)
      setEmailCopied(true)
      window.setTimeout(() => setEmailCopied(false), 2500)
    } catch {
      // Older browsers / non-secure contexts: silently fall back to
      // selecting the textarea so the user can copy manually.
      const ta = document.getElementById(
        'email-body',
      ) as HTMLTextAreaElement | null
      ta?.select()
    }
  }

  if (!invoiceId) {
    return (
      <div className="w-full min-w-0 py-4 sm:py-6">
        <PageHeader title="Contractor invoice" />
        <ErrorState
          title="Missing invoice id"
          message="No invoice id was provided in the URL."
        />
      </div>
    )
  }

  if (isLoading) {
    return (
      <div className="w-full min-w-0 py-4 sm:py-6">
        <PageHeader title="Contractor invoice" />
        <LoadingState message="Loading invoice…" />
      </div>
    )
  }

  if (isError || !data) {
    return (
      <div className="w-full min-w-0 py-4 sm:py-6">
        <PageHeader title="Contractor invoice" />
        <ErrorState
          title="Could not load invoice"
          error={error}
          onRetry={() => void refetch()}
        />
      </div>
    )
  }

  const { header, lines, replaces_invoice_number, replaced_by_invoice_number } = data
  const canMutate = !viewOnly && header.status === 'created'

  return (
    <div
      className="w-full min-w-0 py-4 sm:py-6 print:py-0"
      data-testid="admin-contractor-invoice-detail-page"
    >
      {/*
        Page-level title / subtitle removed per spec — the invoice card now
        starts directly below the app header chrome and serves as its own
        document heading. Feedback toast + internal-note panel stay above
        the invoice row but are hidden in print.
      */}
      <div className="print-hide">
        {feedback ? (
          <div
            className={`mb-4 rounded-md border px-3 py-2 text-sm ${
              feedback.kind === 'success'
                ? 'border-emerald-200 bg-emerald-50 text-emerald-800'
                : 'border-rose-200 bg-rose-50 text-rose-800'
            }`}
            role="status"
          >
            {feedback.message}
          </div>
        ) : null}

        {header.internal_note ? (
          <div className="mb-4 rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-xs text-slate-700">
            <span className="font-semibold">Internal note:</span>{' '}
            {header.internal_note}
          </div>
        ) : null}
      </div>

      {/*
        Two-column content row on desktop: invoice card on the left,
        vertical action stack on the right (top-aligned, fixed-width so
        all four buttons share the same width via `w-full`).
        The left column is intentionally **not** `flex-1` so it shrinks
        to the invoice card's intrinsic width (its `max-w-4xl`), placing
        the action stack flush against the card rather than far across
        the page. `lg:gap-8` (32 px) matches the AppShell's sidebar →
        main padding (`lg:px-8`) so the gap between the card and the
        buttons visually equals the gap between the sidebar and the card.
        `flex-col-reverse` at < lg keeps the action buttons visible above
        the long invoice card on phone / tablet.
      */}
      <div className="flex flex-col-reverse gap-4 lg:flex-row lg:items-start lg:gap-8">
        <div className="min-w-0 lg:flex-none">
          <ContractorInvoicePrintView
            header={header}
            lines={lines}
            replacesInvoiceNumber={replaces_invoice_number}
            replacedByInvoiceNumber={replaced_by_invoice_number}
            onOpenInvoice={setInvoiceDetailRef}
          />
        </div>

        <aside
          className="print-hide flex w-full flex-col gap-2 lg:w-44 lg:shrink-0"
          aria-label="Invoice actions"
        >
          <Link
            to={`/app/admin/contractor-invoices?pay_week=${header.pay_week_start}`}
            className="w-full rounded-md border border-slate-200 bg-white px-3 py-2 text-center text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Back to batch
          </Link>
          <button
            type="button"
            onClick={() => window.print()}
            className="w-full rounded-md bg-slate-900 px-3 py-2 text-center text-sm font-medium text-white hover:bg-slate-800"
          >
            Print / Save as PDF
          </button>
          <button
            type="button"
            onClick={() => {
              setEmailCopied(false)
              setEmailOpen(true)
            }}
            disabled={!hasContractorEmail}
            title={
              hasContractorEmail
                ? 'Email this invoice to the staff member'
                : 'No contractor email saved for this invoice.'
            }
            className="w-full rounded-md border border-slate-200 bg-white px-3 py-2 text-center text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Email to staff member
          </button>
          {!hasContractorEmail ? (
            <p className="text-[11px] leading-snug text-slate-500">
              No contractor email saved for this invoice.
            </p>
          ) : null}
          {canMutate ? (
            <button
              type="button"
              onClick={() => setVoidOpen(true)}
              className="w-full rounded-md border border-rose-200 bg-white px-3 py-2 text-center text-sm font-medium text-rose-700 hover:bg-rose-50"
            >
              Void
            </button>
          ) : null}
        </aside>
      </div>

      {/*
        Reuse the KPI drilldown InvoiceDetailModal so clicking a source
        invoice number on the saved invoice opens the same per-line
        breakdown the KPI page uses, without navigating away. Click and
        Escape behaviour mirror the KPI implementation.
      */}
      <InvoiceDetailModal
        open={invoiceDetailRef !== null}
        onClose={() => setInvoiceDetailRef(null)}
        invoice={invoiceDetailRef?.invoice ?? null}
        locationId={invoiceDetailRef?.locationId ?? null}
        saleDate={invoiceDetailRef?.saleDate ?? null}
      />

      {/*
        Email helper — opens a simple modal with the prefilled To /
        Subject / Body that the user can either copy or hand off to the
        OS email client via mailto:. mailto cannot attach files, so the
        modal also reminds the user to attach the saved PDF manually.
        No backend / SMTP / Resend / Storage / server-side PDF involved.
      */}
      {emailOpen ? (
        <div
          className="print-hide fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
          role="dialog"
          aria-modal="true"
          aria-labelledby="email-modal-title"
          onClick={() => setEmailOpen(false)}
        >
          <div
            className="w-full max-w-lg rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
            onClick={(e) => e.stopPropagation()}
          >
            <h2
              id="email-modal-title"
              className="text-lg font-semibold text-slate-900"
            >
              Email invoice to staff member
            </h2>
            <p className="mt-1 text-xs text-slate-500">
              The PDF cannot be auto-attached. After saving the invoice as
              PDF (Print / Save as PDF), attach it to the email before
              sending.
            </p>

            <div className="mt-4 space-y-3">
              <div>
                <label
                  className="block text-xs font-semibold uppercase tracking-wide text-slate-500"
                  htmlFor="email-to"
                >
                  To
                </label>
                <input
                  id="email-to"
                  type="email"
                  readOnly
                  value={emailDraft.to}
                  className="mt-1 w-full rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-800 focus:outline-none"
                />
              </div>
              <div>
                <label
                  className="block text-xs font-semibold uppercase tracking-wide text-slate-500"
                  htmlFor="email-subject"
                >
                  Subject
                </label>
                <input
                  id="email-subject"
                  type="text"
                  readOnly
                  value={emailDraft.subject}
                  className="mt-1 w-full rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-800 focus:outline-none"
                />
              </div>
              <div>
                <label
                  className="block text-xs font-semibold uppercase tracking-wide text-slate-500"
                  htmlFor="email-body"
                >
                  Message
                </label>
                <textarea
                  id="email-body"
                  readOnly
                  rows={8}
                  value={emailDraft.body}
                  className="mt-1 w-full rounded-md border border-slate-200 bg-slate-50 px-3 py-2 font-mono text-[12.5px] leading-relaxed text-slate-800 focus:outline-none"
                />
              </div>
            </div>

            <div className="mt-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-[11px] leading-snug text-amber-900">
              Reminder: After saving the invoice as PDF, attach it to the
              email before sending — mailto cannot include attachments.
            </div>

            <div className="mt-4 flex flex-wrap items-center justify-end gap-2">
              {emailCopied ? (
                <span
                  className="mr-auto text-xs font-medium text-emerald-700"
                  role="status"
                  aria-live="polite"
                >
                  Copied to clipboard.
                </span>
              ) : null}
              <button
                type="button"
                onClick={() => void copyEmailDraft()}
                className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Copy message
              </button>
              <a
                href={mailtoHref}
                className="rounded-md bg-slate-900 px-3 py-2 text-sm font-medium text-white hover:bg-slate-800"
              >
                Open email
              </a>
              <button
                type="button"
                onClick={() => setEmailOpen(false)}
                className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Close
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {/* Void dialog */}
      {voidOpen ? (
        <div
          className="print-hide fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
          role="dialog"
          aria-modal="true"
          onClick={() => setVoidOpen(false)}
        >
          <div
            className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
            onClick={(e) => e.stopPropagation()}
          >
            <h2 className="text-lg font-semibold text-slate-900">Void invoice</h2>
            <p className="mt-2 text-sm text-slate-600">
              Voiding {headerNumber} will mark it as voided in the audit history.
              A reason is required.
            </p>
            <label
              className="mt-3 block text-sm font-medium text-slate-700"
              htmlFor="void-reason"
            >
              Reason
            </label>
            <textarea
              id="void-reason"
              value={voidReason}
              onChange={(e) => setVoidReason(e.target.value)}
              rows={3}
              className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-rose-500 focus:outline-none focus:ring-1 focus:ring-rose-500"
            />
            <div className="mt-4 flex justify-end gap-2">
              <button
                type="button"
                onClick={() => setVoidOpen(false)}
                className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancel
              </button>
              <button
                type="button"
                disabled={
                  voidReason.trim() === '' || voidMut.isPending
                }
                onClick={() => setConfirmVoid(true)}
                className="rounded-md bg-rose-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-rose-700 disabled:opacity-50"
              >
                {voidMut.isPending ? 'Voiding…' : 'Void invoice'}
              </button>
            </div>
          </div>
        </div>
      ) : null}

      <ConfirmDialog
        open={confirmVoid}
        title={`Void ${headerNumber}?`}
        description="This action marks the invoice as voided. It will remain viewable for audit history but is no longer the active invoice."
        confirmLabel="Void"
        tone="danger"
        onConfirm={() => voidMut.mutate()}
        onClose={() => setConfirmVoid(false)}
      />
    </div>
  )
}
