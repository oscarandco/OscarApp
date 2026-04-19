import { Link, useNavigate, useParams } from 'react-router-dom'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useDeleteSavedQuote } from '@/features/quote/hooks/useDeleteSavedQuote'
import { useSavedQuoteDetail } from '@/features/quote/hooks/useSavedQuoteDetail'
import type { RequoteNavState } from '@/features/quote/lib/requoteFromSavedQuote'
import type {
  SavedQuoteDetail,
  SavedQuoteDetailLine,
} from '@/features/quote/types/savedQuoteDetail'
import {
  formatDateTimeCompact,
  formatNzd,
  formatShortDate,
} from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'

const roleLabels: Record<string, string> = {
  EMERGING: 'Emerging',
  SENIOR: 'Senior',
  MASTER: 'Master',
  DIRECTOR: 'Director',
}

export function SavedQuoteDetailPage() {
  const { quoteId } = useParams<{ quoteId: string }>()
  const navigate = useNavigate()
  const { data, isLoading, isError, error, refetch } = useSavedQuoteDetail(
    quoteId,
  )
  const deleteMutation = useDeleteSavedQuote()

  // A non-elevated user cannot load another stylist's quote via the
  // detail RPC, so successfully reading `data` here is itself proof that
  // the current user is allowed to delete it. The delete RPC enforces
  // the same rule server-side as a belt-and-braces check.
  const onDelete = () => {
    if (!data) return
    // Belt-and-braces dedupe: the Delete button is disabled while a
    // delete is in flight, but guard the handler too so any other
    // trigger (keyboard, tests) can't queue a second mutate.
    if (deleteMutation.isPending) return
    const label = data.header.guestName?.trim() || 'this quote'
    if (!window.confirm(`Delete quote for ${label}? This cannot be undone.`)) {
      return
    }
    deleteMutation.mutate(data.header.id, {
      onSuccess: () => {
        navigate('/app/previous-quotes', {
          replace: true,
          state: { deletedGuest: label },
        })
      },
    })
  }

  const deleteError = deleteMutation.isError
    ? (queryErrorDetail(deleteMutation.error).err?.message ??
      queryErrorDetail(deleteMutation.error).message ??
      'Unable to delete quote.')
    : null

  // Requote: hand the detail payload to the Guest Quote page via
  // navigation state. No backend call, no write to the source quote.
  // The Guest Quote page maps this into a fresh local draft and shows
  // an info banner.
  const onRequote = () => {
    if (!data) return
    const state: RequoteNavState = {
      kind: 'requote-from-saved',
      sourceSavedQuoteId: data.header.id,
      detail: data,
    }
    navigate('/app/guest-quote', { state })
  }

  const backLink = (
    <Link
      to="/app/previous-quotes"
      className="inline-flex items-center rounded-md border border-slate-200 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 shadow-sm hover:bg-slate-50"
      data-testid="saved-quote-detail-back"
    >
      ← Previous Quotes
    </Link>
  )

  // Delete is rendered inside the same header actions slot. Only shown
  // once the quote has loaded successfully — there's nothing meaningful
  // to delete before that.
  const deleteButton = data ? (
    <button
      type="button"
      onClick={onDelete}
      disabled={deleteMutation.isPending}
      aria-busy={deleteMutation.isPending}
      className="inline-flex items-center rounded-md border border-rose-200 bg-white px-3 py-1.5 text-sm font-medium text-rose-700 shadow-sm hover:bg-rose-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-rose-500 focus-visible:ring-offset-1 disabled:cursor-wait disabled:opacity-50"
      data-testid="saved-quote-detail-delete"
    >
      {deleteMutation.isPending ? 'Deleting…' : 'Delete'}
    </button>
  ) : null

  // Requote button: available whenever the user can view the quote
  // (successful detail load). The source quote is never mutated.
  const requoteButton = data ? (
    <button
      type="button"
      onClick={onRequote}
      disabled={deleteMutation.isPending}
      className="inline-flex items-center rounded-md border border-violet-200 bg-white px-3 py-1.5 text-sm font-medium text-violet-700 shadow-sm hover:bg-violet-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1 disabled:cursor-not-allowed disabled:opacity-50"
      data-testid="saved-quote-detail-requote"
    >
      Requote
    </button>
  ) : null

  const headerActions = (
    <>
      {backLink}
      {requoteButton}
      {deleteButton}
    </>
  )

  if (!quoteId) {
    return (
      <div data-testid="saved-quote-detail-page">
        <PageHeader title="Quote Details" actions={backLink} />
        <ErrorState
          title="Quote not found"
          message="The quote id is missing from the URL."
          testId="saved-quote-detail-missing-id"
        />
      </div>
    )
  }

  if (isLoading) {
    return (
      <div data-testid="saved-quote-detail-page">
        <PageHeader title="Quote Details" actions={backLink} />
        <LoadingState
          message="Loading quote…"
          testId="saved-quote-detail-loading"
        />
      </div>
    )
  }

  if (isError || !data) {
    const { message, err } = queryErrorDetail(error)
    // The RPC returns a generic "quote not found" error for both
    // genuinely-missing ids and quotes belonging to another stylist, so
    // the same UI state covers both.
    return (
      <div data-testid="saved-quote-detail-page">
        <PageHeader title="Quote Details" actions={backLink} />
        <ErrorState
          title="Could not load quote"
          error={err}
          message={
            message ??
            'The quote may have been removed, or you may not have access to it.'
          }
          onRetry={() => void refetch()}
          testId="saved-quote-detail-error"
        />
      </div>
    )
  }

  return (
    <div data-testid="saved-quote-detail-page">
      <PageHeader title="Quote Details" actions={headerActions} />
      {deleteError ? (
        <div
          role="alert"
          className="mb-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-800"
          data-testid="saved-quote-detail-delete-error"
        >
          {deleteError}
        </div>
      ) : null}
      <QuoteDetailHeaderCard detail={data} />
      <QuoteDetailLines detail={data} />
      <QuoteDetailTotals detail={data} />
    </div>
  )
}

function QuoteDetailHeaderCard({ detail }: { detail: SavedQuoteDetail }) {
  const { header } = detail
  return (
    <section
      className="mb-4 rounded-lg border border-slate-200 bg-white px-4 py-3 shadow-sm"
      data-testid="saved-quote-detail-header"
    >
      <dl className="grid grid-cols-1 gap-x-6 gap-y-2 sm:grid-cols-2 lg:grid-cols-4">
        <HeaderField label="Guest">
          {header.guestName?.trim() || (
            <span className="italic text-slate-400">No name</span>
          )}
        </HeaderField>
        <HeaderField label="Stylist">{header.stylistDisplayName}</HeaderField>
        <HeaderField label="Quote date">
          {formatShortDate(header.quoteDate)}
        </HeaderField>
        <HeaderField label="Saved at">
          {formatDateTimeCompact(header.createdAt)}
        </HeaderField>
      </dl>
      {header.notes ? (
        <div className="mt-3 border-t border-slate-100 pt-3">
          <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
            Notes
          </p>
          {/*
            `whitespace-pre-wrap` preserves the user's line breaks, but
            on its own does not break inside an unbroken token (long
            URL, glued string, etc.) — those would push the card width
            and force horizontal page overflow on mobile. `break-words`
            (overflow-wrap: break-word) covers the common long-word /
            long-URL case, and the arbitrary
            `[overflow-wrap:anywhere]` is a safety net for pathological
            inputs with no natural break opportunity at all.
          */}
          <p className="mt-1 whitespace-pre-wrap break-words text-sm text-slate-800 [overflow-wrap:anywhere]">
            {header.notes}
          </p>
        </div>
      ) : null}
    </section>
  )
}

function HeaderField({
  label,
  children,
}: {
  label: string
  children: React.ReactNode
}) {
  return (
    <div>
      <dt className="text-xs font-semibold uppercase tracking-wide text-slate-500">
        {label}
      </dt>
      <dd className="mt-0.5 text-sm text-slate-900">{children}</dd>
    </div>
  )
}

/** Short secondary line beneath the service name describing what was picked. */
function lineMetaText(line: SavedQuoteDetailLine): string | null {
  const parts: string[] = []

  if (line.selectedRole) {
    parts.push(`Role: ${roleLabels[line.selectedRole] ?? line.selectedRole}`)
  }

  if (line.selectedOptions.length > 0) {
    parts.push(line.selectedOptions.map((o) => o.label).join(', '))
  }

  if (line.numericQuantity != null && line.numericQuantity > 0) {
    const unit = line.numericUnitLabel ?? ''
    parts.push(`${line.numericQuantity}${unit ? ` ${unit}` : ''}`)
  }

  if (line.extraUnitsSelected != null && line.extraUnitsSelected > 0) {
    parts.push(
      `${line.extraUnitsSelected} extra${
        line.extraUnitsSelected === 1 ? '' : 's'
      }`,
    )
  }

  if (line.pricingType === 'special_extra_product') {
    const rows = Array.isArray(line.specialExtraRows)
      ? (line.specialExtraRows as Array<Record<string, unknown>>)
      : []
    let totalUnits = 0
    let totalGrams = 0
    for (const r of rows) {
      const u = Number(r?.units ?? 0)
      const g = Number(r?.grams ?? 0)
      if (Number.isFinite(u)) totalUnits += u
      if (Number.isFinite(g)) totalGrams += g
    }
    if (totalUnits > 0 || totalGrams > 0) {
      parts.push(`${totalUnits} units / ${totalGrams} g`)
    }
  }

  return parts.length > 0 ? parts.join(' · ') : null
}

function QuoteDetailLines({ detail }: { detail: SavedQuoteDetail }) {
  // Group in insertion (lineOrder) order but keep one rendered block per
  // consecutive section — matches how the stylist built the quote.
  const groups: Array<{ sectionKey: string; title: string; lines: SavedQuoteDetailLine[] }> =
    []
  for (const line of detail.lines) {
    const sectionKey = line.sectionId ?? line.sectionName
    const last = groups[groups.length - 1]
    if (last && last.sectionKey === sectionKey) {
      last.lines.push(line)
    } else {
      groups.push({
        sectionKey,
        title: line.sectionName || line.sectionSummaryLabel,
        lines: [line],
      })
    }
  }

  if (groups.length === 0) {
    return (
      <section
        className="mb-4 rounded-lg border border-dashed border-slate-200 bg-white px-6 py-12 text-center"
        data-testid="saved-quote-detail-empty-lines"
      >
        <p className="text-sm font-medium text-slate-800">
          No services recorded on this quote.
        </p>
      </section>
    )
  }

  return (
    <section className="mb-4 space-y-3" data-testid="saved-quote-detail-lines">
      {groups.map((group, idx) => (
        <div
          key={`${group.sectionKey}-${idx}`}
          className="overflow-hidden rounded-lg border border-slate-200 bg-white shadow-sm"
        >
          <h3 className="border-b border-slate-100 bg-slate-50 px-3 py-2 text-xs font-semibold uppercase tracking-wide text-slate-700">
            {group.title}
          </h3>
          <ul className="divide-y divide-slate-100">
            {group.lines.map((line) => (
              <li
                key={line.id}
                className="flex items-start justify-between gap-4 px-3 py-2"
                data-testid={`saved-quote-detail-line-${line.id}`}
              >
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-medium text-slate-900">
                    {line.serviceName}
                  </p>
                  {lineMetaText(line) ? (
                    <p className="mt-0.5 text-xs text-slate-600">
                      {lineMetaText(line)}
                    </p>
                  ) : null}
                </div>
                <div className="shrink-0 text-right text-sm font-semibold tabular-nums text-slate-900">
                  {formatNzd(line.lineTotal)}
                </div>
              </li>
            ))}
          </ul>
        </div>
      ))}
    </section>
  )
}

function QuoteDetailTotals({ detail }: { detail: SavedQuoteDetail }) {
  const { header, sectionTotals } = detail
  return (
    <section
      className="rounded-lg border border-slate-200 bg-white px-4 py-3 shadow-sm"
      data-testid="saved-quote-detail-totals"
    >
      <h3 className="mb-2 text-xs font-semibold uppercase tracking-wide text-slate-700">
        Summary
      </h3>
      <dl className="divide-y divide-slate-100 text-sm">
        {sectionTotals.map((t) => (
          <div
            key={`${t.displayOrder}-${t.summaryLabel}`}
            className="flex items-center justify-between py-1.5"
          >
            <dt className="text-slate-700">{t.summaryLabel}</dt>
            <dd className="tabular-nums text-slate-900">
              {formatNzd(t.sectionTotal)}
            </dd>
          </div>
        ))}
        <div className="flex items-center justify-between py-1.5">
          <dt className="text-slate-700">Green Fee</dt>
          <dd className="tabular-nums text-slate-900">
            {formatNzd(header.greenFeeApplied)}
          </dd>
        </div>
      </dl>
      <div className="mt-2 flex items-center justify-between border-t border-slate-200 pt-2">
        <span className="text-sm font-semibold text-slate-900">Total</span>
        <span
          className="text-base font-semibold tabular-nums text-slate-900"
          data-testid="saved-quote-detail-grand-total"
        >
          {formatNzd(header.grandTotal)}
        </span>
      </div>
    </section>
  )
}
