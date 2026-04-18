import { useMemo, useState } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { useAccessProfile } from '@/features/access/accessContext'
import { GuestQuoteServiceField } from '@/features/quote/components/GuestQuoteServiceField'
import { GuestQuoteSummary } from '@/features/quote/components/GuestQuoteSummary'
import { useStylistQuoteConfig } from '@/features/quote/hooks/useStylistQuoteConfig'
import { buildQuoteSummary } from '@/features/quote/lib/quoteCalculations'
import {
  clearLine,
  emptyDraft,
  lineFor,
  reconcileDraftWithConfig,
  resetDraft,
  updateLine,
  type GuestQuoteDraft,
  type GuestQuoteLineDraft,
} from '@/features/quote/state/guestQuoteDraft'
import type {
  StylistQuoteConfig,
  StylistQuoteSection,
} from '@/features/quote/types/stylistQuoteConfig'
import { formatNzd } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'

/**
 * Stylist-facing Guest Quote page.
 *
 * Narrow, centered worksheet-style layout designed to match the salon's
 * existing tool. Holds the in-progress quote entirely in local state;
 * save is intentionally not wired yet (Submit Quote is shown but
 * disabled).
 */
export function GuestQuotePage() {
  const { data, isLoading, isError, error, refetch } = useStylistQuoteConfig()

  if (isLoading) {
    return (
      <div data-testid="guest-quote-page">
        <LoadingState
          message="Loading guest quote…"
          testId="guest-quote-loading"
        />
      </div>
    )
  }

  if (isError || !data) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="guest-quote-page">
        <ErrorState
          title="Could not load quote configuration"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="guest-quote-error"
        />
      </div>
    )
  }

  if (!data.settings.active) {
    return (
      <div className="max-w-[620px]" data-testid="guest-quote-page">
        <h1 className="mb-3 text-lg font-semibold text-slate-900">
          {data.settings.quotePageTitle || 'Guest Quote'}
        </h1>
        <div
          className="rounded-md border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900"
          role="alert"
          data-testid="guest-quote-inactive"
        >
          Guest Quote is currently disabled. Ask an admin to enable it from{' '}
          <span className="font-medium">Quote Configuration</span>.
        </div>
      </div>
    )
  }

  return <GuestQuoteForm config={data} />
}

function GuestQuoteForm({ config }: { config: StylistQuoteConfig }) {
  const { normalized } = useAccessProfile()
  const stylistDisplayName =
    normalized?.staffDisplayName || normalized?.staffFullName || ''

  const [draft, setDraft] = useState<GuestQuoteDraft>(() => emptyDraft())

  const reconciled = useMemo(
    () => reconcileDraftWithConfig(draft, config),
    [draft, config],
  )
  const liveDraft = reconciled === draft ? draft : reconciled

  const summary = useMemo(
    () => buildQuoteSummary(config, liveDraft),
    [config, liveDraft],
  )

  /**
   * Pre-compute linked-extra lookups so patch handlers can propagate
   * selection changes both ways:
   *   - picking an extra auto-activates its base service
   *   - clearing a base service cascades to clear its linked extras
   */
  const linkIndex = useMemo(() => {
    const linkToBaseId = new Map<string, string>()
    const extrasByBaseId = new Map<string, string[]>()
    for (const sec of config.sections) {
      for (const svc of sec.services) {
        const baseId = svc.linkToBaseServiceId
        if (!baseId) continue
        linkToBaseId.set(svc.id, baseId)
        const list = extrasByBaseId.get(baseId) ?? []
        list.push(svc.id)
        extrasByBaseId.set(baseId, list)
      }
    }
    return { linkToBaseId, extrasByBaseId }
  }, [config])

  const onPatchLine = (
    serviceId: string,
    patch: Partial<GuestQuoteLineDraft>,
  ) =>
    setDraft((prev) => {
      let next = updateLine(prev, serviceId, patch)

      // Activating a linked extra → auto-activate its base service.
      if (patch.selected === true) {
        const baseId = linkIndex.linkToBaseId.get(serviceId)
        if (baseId) {
          next = updateLine(next, baseId, { selected: true })
        }
      }

      // Deactivating a base service → cascade clear to linked extras.
      if (patch.selected === false) {
        const linked = linkIndex.extrasByBaseId.get(serviceId)
        if (linked) {
          for (const extraId of linked) next = clearLine(next, extraId)
        }
      }

      return next
    })

  const onClearLine = (serviceId: string) =>
    setDraft((prev) => {
      let next = clearLine(prev, serviceId)
      const linked = linkIndex.extrasByBaseId.get(serviceId)
      if (linked) {
        for (const extraId of linked) next = clearLine(next, extraId)
      }
      return next
    })

  const onResetForm = () => setDraft(resetDraft())

  return (
    <div
      className="w-full max-w-[620px] text-[13px] text-slate-900"
      data-testid="guest-quote-page"
    >
      {/* Top row — guest on the left, stylist on the right, with their
          action buttons sitting directly underneath, mirroring the
          reference worksheet. */}
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="space-y-2">
          <div className="flex items-center gap-2">
            <label
              htmlFor="guest-name"
              className="w-16 shrink-0 text-slate-700"
            >
              Guest
            </label>
            <input
              id="guest-name"
              type="text"
              value={liveDraft.guestName}
              onChange={(e) =>
                setDraft((prev) => ({ ...prev, guestName: e.target.value }))
              }
              className="flex-1 rounded border border-slate-300 bg-white px-2 py-1 text-[13px] focus:border-emerald-400 focus:outline-none focus:ring-1 focus:ring-emerald-400"
            />
          </div>
          <div className="pl-[72px]">
            <button
              type="button"
              onClick={onResetForm}
              className="rounded-full border border-slate-300 px-3 py-0.5 text-[12px] font-medium text-slate-700 hover:bg-slate-50"
              data-testid="guest-quote-reset-form"
            >
              Reset Form
            </button>
          </div>
        </div>
        <div className="space-y-2">
          <div className="flex items-center gap-2">
            <label
              htmlFor="stylist-name"
              className="w-16 shrink-0 text-slate-700"
            >
              Stylist
            </label>
            <input
              id="stylist-name"
              type="text"
              value={stylistDisplayName}
              readOnly
              placeholder="—"
              className="flex-1 rounded border border-slate-300 bg-slate-50 px-2 py-1 text-[13px] text-slate-700"
            />
          </div>
          <div className="pl-[72px]">
            <button
              type="button"
              disabled
              aria-disabled="true"
              title="Save coming soon"
              className="cursor-not-allowed rounded-full border border-dashed border-slate-300 bg-slate-50 px-3 py-0.5 text-[12px] font-medium text-slate-500"
              data-testid="guest-quote-submit"
            >
              Submit Quote
            </button>
          </div>
        </div>
      </div>

      {/* Notes — only rendered when settings.notes_enabled is true. */}
      {config.settings.notesEnabled ? (
        <div className="mt-3 flex items-start gap-2">
          <label
            htmlFor="guest-notes"
            className="w-16 shrink-0 pt-1 text-slate-700"
          >
            Notes
          </label>
          <textarea
            id="guest-notes"
            rows={2}
            value={liveDraft.notes}
            onChange={(e) =>
              setDraft((prev) => ({ ...prev, notes: e.target.value }))
            }
            className="flex-1 rounded border border-slate-300 bg-white px-2 py-1 text-[13px] focus:border-emerald-400 focus:outline-none focus:ring-1 focus:ring-emerald-400"
          />
        </div>
      ) : null}

      {/* Sections — each section is its own subtle box; alternating
          white / very light grey panels against the slate-50 page bg
          read as distinct containers without needing heavy borders. */}
      <div className="mt-4 space-y-2">
        {config.sections.map((section, idx) => (
          <SectionBlock
            key={section.id}
            section={section}
            draft={liveDraft}
            shaded={idx % 2 === 1}
            onPatchLine={onPatchLine}
            onClearLine={onClearLine}
          />
        ))}
      </div>

      {/* Green Fee shown as a worksheet-style line just above the
          summary table, matching the reference — purely informational,
          always included in the total below. */}
      <div
        className="mt-4 grid grid-cols-[20px_56px_240px_minmax(0,1fr)] items-center gap-x-1.5 px-3 py-1 text-[13px]"
        data-testid="guest-quote-green-fee-row"
      >
        <span aria-hidden="true" />
        <span className="truncate font-semibold text-emerald-600">
          {formatNzd(summary.greenFee)}
        </span>
        <span className="text-slate-800">Green Fee</span>
        <span aria-hidden="true" />
      </div>

      <GuestQuoteSummary summary={summary} />
    </div>
  )
}

function SectionBlock({
  section,
  draft,
  shaded,
  onPatchLine,
  onClearLine,
}: {
  section: StylistQuoteSection
  draft: GuestQuoteDraft
  shaded: boolean
  onPatchLine: (serviceId: string, patch: Partial<GuestQuoteLineDraft>) => void
  onClearLine: (serviceId: string) => void
}) {
  return (
    <section
      className={`rounded-md px-3 py-2.5 ${
        shaded ? 'bg-slate-100/80' : 'bg-white'
      }`}
      data-testid={`guest-quote-section-${section.id}`}
    >
      <h2 className="pb-1 text-[11px] font-semibold uppercase tracking-wide text-slate-700">
        {section.name}
      </h2>
      {section.sectionHelpText ? (
        <p className="pb-1 text-[11px] text-slate-500">
          {section.sectionHelpText}
        </p>
      ) : null}
      <div>
        {section.services.map((svc) => {
          const line = lineFor(draft, svc.id)
          return (
            <GuestQuoteServiceField
              key={svc.id}
              service={svc}
              line={line}
              onChange={(patch) => onPatchLine(svc.id, patch)}
              onClear={() => onClearLine(svc.id)}
            />
          )
        })}
      </div>
    </section>
  )
}
