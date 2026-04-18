import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useRef, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import {
  QuoteServiceDrawer,
  type QuoteServiceDrawerMode,
} from '@/features/admin/components/QuoteServiceDrawer'
import { quoteConfigurationQueryKey } from '@/features/admin/hooks/useQuoteConfiguration'
import type { QuoteService } from '@/features/admin/types/quoteConfiguration'
import {
  useAccessProfile,
  useHasElevatedAccess,
} from '@/features/access/accessContext'
import { GuestQuoteServiceField } from '@/features/quote/components/GuestQuoteServiceField'
import { guestQuoteRowGridClasses } from '@/features/quote/components/guestQuoteRowGrid'
import { GuestQuoteSummary } from '@/features/quote/components/GuestQuoteSummary'
import {
  buildSaveGuestQuotePayload,
  SaveGuestQuoteValidationError,
} from '@/features/quote/data/saveGuestQuoteApi'
import { useSaveGuestQuote } from '@/features/quote/hooks/useSaveGuestQuote'
import {
  stylistQuoteConfigQueryKey,
  useStylistQuoteConfig,
} from '@/features/quote/hooks/useStylistQuoteConfig'
import {
  buildDisplayedRowTotals,
  buildQuoteSummary,
} from '@/features/quote/lib/quoteCalculations'
import {
  buildRequoteDraftFromSaved,
  type RequoteNavState,
} from '@/features/quote/lib/requoteFromSavedQuote'
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
import {
  fetchQuoteConfiguration,
  saveQuoteService,
} from '@/lib/quoteConfigurationApi'
import { queryErrorDetail } from '@/lib/queryError'

/**
 * Stylist-facing Guest Quote page.
 *
 * Narrow, centered worksheet-style layout designed to match the salon's
 * existing tool. Holds the in-progress quote entirely in local state;
 * save is intentionally not wired yet (Submit Quote is shown but
 * disabled).
 */

/**
 * Narrow a react-router `location.state` into the requote payload if
 * it's shaped like one. Anything else (unknown nav state, a plain
 * object from another feature, null) returns null so the Guest Quote
 * page starts blank as usual.
 */
function readRequoteState(raw: unknown): RequoteNavState | null {
  if (!raw || typeof raw !== 'object') return null
  const maybe = raw as { kind?: unknown }
  if (maybe.kind !== 'requote-from-saved') return null
  const state = raw as RequoteNavState
  if (!state.detail || !state.detail.header) return null
  return state
}

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
  const isElevated = useHasElevatedAccess()
  const queryClient = useQueryClient()

  // Requote prefill: consume `location.state.requote` exactly once on
  // mount. We seed both the draft and the "loaded from previous quote"
  // banner synchronously so the form never flickers from empty to
  // prefilled. The history state is cleared right after read so a page
  // refresh or a bounce back to this route won't silently re-seed on
  // top of the stylist's in-progress edits.
  const location = useLocation()
  const navigate = useNavigate()
  const requoteSeedRef = useRef<RequoteNavState | null>(
    readRequoteState(location.state),
  )

  const initialMapping = useMemo(() => {
    const seed = requoteSeedRef.current
    if (!seed) return null
    return buildRequoteDraftFromSaved(seed.detail, config)
    // We intentionally only compute this once for the initial seed.
    // Subsequent config refetches must not reset the stylist's edits.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const [draft, setDraft] = useState<GuestQuoteDraft>(
    () => initialMapping?.draft ?? emptyDraft(),
  )

  // A per-mount snapshot of the skipped-services list that drove the
  // initial prefill. Kept in local state so the stylist can dismiss the
  // banner on reset/submit without losing the prefill itself.
  const [requoteInfo, setRequoteInfo] = useState<
    { skippedServiceNames: string[] } | null
  >(() =>
    initialMapping
      ? { skippedServiceNames: initialMapping.skippedServiceNames }
      : null,
  )

  // Strip the requote nav state after consuming it. Runs once.
  useEffect(() => {
    if (requoteSeedRef.current) {
      navigate(location.pathname, { replace: true, state: null })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const reconciled = useMemo(
    () => reconcileDraftWithConfig(draft, config),
    [draft, config],
  )
  const liveDraft = reconciled === draft ? draft : reconciled

  const summary = useMemo(
    () => buildQuoteSummary(config, liveDraft),
    [config, liveDraft],
  )

  // Per-row displayed totals: same id→amount map, computed once per
  // render. Parent rows include linked-child contributions; linked
  // child rows map to `null` so they render as "—" instead of a
  // standalone green amount. Grand total / save payload stay on the
  // raw per-line totals so this rollup is display-only.
  const displayedTotalsById = useMemo(
    () => buildDisplayedRowTotals(config, liveDraft),
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

  const saveMutation = useSaveGuestQuote()

  // Transient success banner + client-side validation error, kept in
  // local state so they clear cleanly after the next edit.
  const [validationError, setValidationError] = useState<string | null>(null)
  const [lastSavedId, setLastSavedId] = useState<string | null>(null)

  // ---------------------------------------------------------------
  // Admin-only: per-service edit shortcut into the existing Quote
  // Configuration service drawer. Everything below is inert for
  // non-elevated users — the drawer state is never populated and
  // the E button is never rendered.
  // ---------------------------------------------------------------
  const [adminDrawer, setAdminDrawer] = useState<
    | {
        mode: QuoteServiceDrawerMode
        service: QuoteService
        // Captured alongside the opened service so the drawer can
        // render the "Link To Base Service" dropdown. Updated each
        // time the drawer is opened; never mutated during editing.
        allServices: readonly QuoteService[]
      }
    | null
  >(null)
  const [adminLoadingServiceId, setAdminLoadingServiceId] = useState<
    string | null
  >(null)
  const [adminError, setAdminError] = useState<string | null>(null)
  const [adminConfigRefreshed, setAdminConfigRefreshed] = useState(false)

  const saveServiceMut = useMutation({
    mutationFn: (args: {
      id: string | null
      service: Partial<QuoteService> & { name: string; sectionId: string }
    }) => saveQuoteService(args),
    onSuccess: () => {
      // Keep the admin config cache (used by this page's drawer) and
      // the stylist-facing config cache (used to render the Guest
      // Quote worksheet) in sync. The stylist invalidation drives the
      // reconcile step that flows through `reconcileDraftWithConfig`
      // on the next render.
      void queryClient.invalidateQueries({
        queryKey: quoteConfigurationQueryKey,
      })
      void queryClient.invalidateQueries({
        queryKey: stylistQuoteConfigQueryKey,
      })
      setAdminConfigRefreshed(true)
    },
  })

  const onAdminEditService = async (serviceId: string) => {
    if (!isElevated) return
    if (adminLoadingServiceId != null) return
    setAdminError(null)
    setAdminLoadingServiceId(serviceId)
    try {
      // Reuse the admin config cache: if another admin page has
      // already loaded it the drawer opens instantly; otherwise we
      // fetch once and prime the cache for later edits.
      const adminConfig = await queryClient.fetchQuery({
        queryKey: quoteConfigurationQueryKey,
        queryFn: fetchQuoteConfiguration,
      })
      const svc = adminConfig.services.find((s) => s.id === serviceId)
      if (!svc) {
        setAdminError(
          'This service could not be found in the latest configuration. It may have been deleted.',
        )
        return
      }
      setAdminDrawer({
        mode: 'edit',
        service: svc,
        allServices: adminConfig.services,
      })
    } catch (e) {
      setAdminError(
        queryErrorDetail(e).err?.message ??
          'Unable to load service for editing.',
      )
    } finally {
      setAdminLoadingServiceId(null)
    }
  }

  const onAdminDrawerSubmit = (
    payload: Partial<QuoteService> & { name: string; sectionId: string },
    ctx: { mode: QuoteServiceDrawerMode; existingId: string | null },
  ) => {
    const id = ctx.mode === 'edit' ? ctx.existingId : null
    setAdminError(null)
    saveServiceMut.mutate(
      { id, service: payload },
      {
        onError: (err) => {
          setAdminError(
            queryErrorDetail(err).err?.message ?? 'Unable to save service.',
          )
        },
      },
    )
  }

  const onResetForm = () => {
    setDraft(resetDraft())
    setValidationError(null)
    setLastSavedId(null)
    setRequoteInfo(null)
    setAdminConfigRefreshed(false)
    saveMutation.reset()
  }

  const onSubmit = () => {
    // Belt-and-braces dedupe: the Submit button is already disabled while
    // a save is in flight, but any other trigger path (keyboard, tests,
    // future wiring) must not be able to fire a second mutate during the
    // first one — that would race `onSuccess` callbacks and leave the
    // draft in a confused state.
    if (saveMutation.isPending) return

    setValidationError(null)
    setLastSavedId(null)
    let payload
    try {
      payload = buildSaveGuestQuotePayload(config, liveDraft, {
        stylistDisplayName: stylistDisplayName || null,
      })
    } catch (e) {
      if (e instanceof SaveGuestQuoteValidationError) {
        setValidationError(e.message)
        return
      }
      throw e
    }
    saveMutation.mutate(payload, {
      onSuccess: (newId) => {
        // Only clear the draft once the server has confirmed the save —
        // if the save fails, the stylist keeps their work.
        setDraft(resetDraft())
        setLastSavedId(newId)
        // The submitted quote is now its own saved record; drop the
        // "loaded from previous quote" banner so the next quote starts
        // with a clean slate.
        setRequoteInfo(null)
        setAdminConfigRefreshed(false)
      },
    })
  }

  const saveError = saveMutation.isError
    ? (queryErrorDetail(saveMutation.error).err?.message ??
      queryErrorDetail(saveMutation.error).message ??
      'Unable to save quote.')
    : null

  // Hide the success banner the moment the stylist starts a new quote.
  const showSuccessBanner = lastSavedId != null && !saveMutation.isPending

  return (
    // Mobile: a tight 8px horizontal breathing pad keeps the top-form
    // inputs aligned with the content inside each section card below
    // (sections carry their own 8px inner pad), so the form area and
    // service list share a consistent left/right rhythm at phone
    // widths. Desktop stays flush (`lg:px-0`) so the worksheet grid
    // retains its established look.
    <div
      className="w-full max-w-[620px] px-1 text-[13px] text-slate-900 lg:px-0"
      data-testid="guest-quote-page"
    >
      {/* Top row — guest on the left, stylist on the right, with their
          action buttons sitting directly underneath, mirroring the
          reference worksheet.
          Mobile (< lg): the whole right-hand Stylist column is hidden
          (the stylist is identified server-side anyway) and the
          Reset/Submit actions are moved to a dedicated mobile-only
          bar below Notes — see `guest-quote-mobile-actions`. The
          mobile boundary is deliberately set at `lg`, not `sm`, so
          iPhones in landscape (≈ 667–932px wide) still get the mobile
          layout instead of the desktop two-column grid. */}
      <div className="grid grid-cols-1 gap-3 lg:grid-cols-2">
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
          <div className="hidden pl-[72px] lg:block">
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
        <div className="hidden space-y-2 lg:block">
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
              onClick={onSubmit}
              disabled={saveMutation.isPending}
              aria-busy={saveMutation.isPending}
              className="rounded-full border border-emerald-600 bg-emerald-600 px-3 py-0.5 text-[12px] font-medium text-white hover:bg-emerald-700 disabled:cursor-wait disabled:bg-emerald-500"
              data-testid="guest-quote-submit"
            >
              {saveMutation.isPending ? 'Saving…' : 'Submit Quote'}
            </button>
          </div>
        </div>
      </div>

      {/* Requote prefill notice — shown once after arriving via the
          Quote Detail → Requote button. Clears on Reset Form or after
          a successful submit. */}
      {requoteInfo ? (
        <div
          role="status"
          className="mt-3 rounded-md border border-violet-200 bg-violet-50 px-3 py-2 text-[12px] text-violet-900"
          data-testid="guest-quote-requote-banner"
        >
          <p className="font-medium">
            Loaded from previous quote. Review before submitting as a new
            quote.
          </p>
          {requoteInfo.skippedServiceNames.length > 0 ? (
            <p className="mt-1 text-violet-800">
              Some items could not be loaded because the quote configuration
              has changed:{' '}
              <span className="font-medium">
                {requoteInfo.skippedServiceNames.join(', ')}
              </span>
              .
            </p>
          ) : null}
        </div>
      ) : null}

      {/* Admin-only: soft notice after a service config save so the
          stylist understands why some draft values may have changed
          under them. Only shown to elevated users — non-admins never
          trigger this path. Dismissed by Reset Form or a successful
          submit. */}
      {isElevated && adminConfigRefreshed ? (
        <div
          role="status"
          className="mt-3 rounded-md border border-sky-200 bg-sky-50 px-3 py-2 text-[12px] text-sky-900"
          data-testid="guest-quote-admin-refreshed"
        >
          Quote configuration was updated. Some selections were refreshed.
        </div>
      ) : null}
      {isElevated && adminError ? (
        <div
          role="alert"
          className="mt-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-[12px] text-rose-800"
          data-testid="guest-quote-admin-error"
        >
          {adminError}
        </div>
      ) : null}

      {/* Save feedback — inline, not toasts, matching the admin pages. */}
      {showSuccessBanner ? (
        <div
          role="status"
          className="mt-3 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-[12px] text-emerald-800"
          data-testid="guest-quote-save-success"
        >
          Quote saved.
        </div>
      ) : null}
      {validationError ? (
        <div
          role="alert"
          className="mt-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-[12px] text-amber-900"
          data-testid="guest-quote-validation-error"
        >
          {validationError}
        </div>
      ) : null}
      {saveError ? (
        <div
          role="alert"
          className="mt-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-[12px] text-rose-800"
          data-testid="guest-quote-save-error"
        >
          {saveError}
        </div>
      ) : null}

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

      {/* Mobile-only action bar — below Notes, matching the requested
          mobile flow. Desktop renders the same actions inline next to
          the Guest / Stylist inputs above, so this block is hidden at
          `lg` and up (iPhone landscape stays on the mobile layout).
          Buttons are sized for comfortable tap targets. */}
      <div
        className="mt-3 flex flex-wrap gap-2 lg:hidden"
        data-testid="guest-quote-mobile-actions"
      >
        <button
          type="button"
          onClick={onResetForm}
          className="flex-1 rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          data-testid="guest-quote-reset-form-mobile"
        >
          Reset Form
        </button>
        <button
          type="button"
          onClick={onSubmit}
          disabled={saveMutation.isPending}
          aria-busy={saveMutation.isPending}
          className="flex-1 rounded-md border border-emerald-600 bg-emerald-600 px-3 py-2 text-sm font-medium text-white hover:bg-emerald-700 disabled:cursor-wait disabled:bg-emerald-500"
          data-testid="guest-quote-submit-mobile"
        >
          {saveMutation.isPending ? 'Saving…' : 'Submit Quote'}
        </button>
      </div>

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
            onAdminEditService={isElevated ? onAdminEditService : undefined}
            adminLoadingServiceId={adminLoadingServiceId}
            displayedTotalsById={displayedTotalsById}
          />
        ))}
      </div>

      {/* Green Fee shown as a worksheet-style line just above the
          summary table, matching the reference — purely informational,
          always included in the total below.
          Desktop (≥ lg): uses the shared Guest Quote grid template so
          the column starts line up with every service row above.
          Mobile (< lg): renders as a simple price + label pair with
          the same rhythm as the stacked mobile row layout. */}
      <div data-testid="guest-quote-green-fee-row" className="mt-4">
        <div className="hidden px-3 lg:block">
          <div className={guestQuoteRowGridClasses(isElevated)}>
            <span aria-hidden="true" />
            <span className="truncate font-semibold text-emerald-600">
              {formatNzd(summary.greenFee)}
            </span>
            <span className="text-slate-800">Green Fee</span>
            <span aria-hidden="true" />
          </div>
        </div>
        <div className="flex items-center gap-2 px-2 py-1 lg:hidden">
          <span aria-hidden="true" className="w-6 shrink-0" />
          <span className="w-[4.5rem] shrink-0 text-right text-[12.5px] font-semibold tabular-nums text-emerald-600">
            {formatNzd(summary.greenFee)}
          </span>
          <span className="min-w-0 flex-1 text-[12.5px] text-slate-800">
            Green Fee
          </span>
        </div>
      </div>

      <GuestQuoteSummary summary={summary} />

      {/* Admin-only service edit drawer — same component used by the
          Quote Configuration pages, opened here for a single service
          at a time. Non-elevated users never reach this render path
          because `adminDrawer` stays null. */}
      {isElevated && adminDrawer ? (
        <QuoteServiceDrawer
          open={true}
          mode={adminDrawer.mode}
          sectionId={adminDrawer.service.sectionId}
          existingService={adminDrawer.service}
          allServices={adminDrawer.allServices}
          onClose={() => setAdminDrawer(null)}
          onSubmit={(payload, ctx) => {
            onAdminDrawerSubmit(payload, ctx)
          }}
          // Intentionally omit onArchive / onDelete so the Guest Quote
          // path never exposes archive/delete controls, per scope.
        />
      ) : null}
    </div>
  )
}

function SectionBlock({
  section,
  draft,
  shaded,
  onPatchLine,
  onClearLine,
  onAdminEditService,
  adminLoadingServiceId,
  displayedTotalsById,
}: {
  section: StylistQuoteSection
  draft: GuestQuoteDraft
  shaded: boolean
  onPatchLine: (serviceId: string, patch: Partial<GuestQuoteLineDraft>) => void
  onClearLine: (serviceId: string) => void
  onAdminEditService: ((serviceId: string) => void) | undefined
  adminLoadingServiceId: string | null
  displayedTotalsById: Map<string, number | null>
}) {
  return (
    <section
      className={`rounded-md px-2 py-2 sm:px-3 sm:py-2.5 ${
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
          const onAdminEdit = onAdminEditService
            ? () => onAdminEditService(svc.id)
            : undefined
          // `buildDisplayedRowTotals` covers every service in the
          // config. An `undefined` only shows up if the config and
          // draft drift mid-render — treat that as 0 so the row
          // never renders a stale amount. A deliberate `null` means
          // "child row, rolled up into parent" and must survive.
          const raw = displayedTotalsById.get(svc.id)
          const displayedTotal: number | null =
            raw === undefined ? 0 : raw
          return (
            <GuestQuoteServiceField
              key={svc.id}
              service={svc}
              line={line}
              onChange={(patch) => onPatchLine(svc.id, patch)}
              onClear={() => onClearLine(svc.id)}
              onAdminEdit={onAdminEdit}
              adminEditBusy={adminLoadingServiceId === svc.id}
              displayedTotal={displayedTotal}
            />
          )
        })}
      </div>
    </section>
  )
}
