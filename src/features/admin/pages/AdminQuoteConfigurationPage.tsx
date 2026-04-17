import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'

import { ConfirmDialog } from '@/components/feedback/ConfirmDialog'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { AddSectionModal } from '@/features/admin/components/AddSectionModal'
import { QuoteSectionsTable } from '@/features/admin/components/QuoteSectionsTable'
import { QuoteSettingsCard } from '@/features/admin/components/QuoteSettingsCard'
import {
  quoteConfigurationQueryKey,
  sectionsInOrder,
  serviceCountForSection,
  useQuoteConfiguration,
} from '@/features/admin/hooks/useQuoteConfiguration'
import type {
  QuoteSection,
  QuoteSettings,
} from '@/features/admin/types/quoteConfiguration'
import {
  deleteQuoteSection,
  insertQuoteSection,
  type InsertSectionInput,
  reorderQuoteSections,
  updateQuoteSection,
  updateQuoteSettings,
} from '@/lib/quoteConfigurationApi'
import { queryErrorDetail } from '@/lib/queryError'

type SectionsFilter = 'active' | 'archived' | 'all'

const FILTER_OPTIONS: { id: SectionsFilter; label: string }[] = [
  { id: 'active', label: 'Active' },
  { id: 'archived', label: 'Archived' },
  { id: 'all', label: 'All' },
]

export function AdminQuoteConfigurationPage() {
  const queryClient = useQueryClient()
  const { data: config, isLoading, isError, error, refetch } =
    useQuoteConfiguration()

  const [addSectionOpen, setAddSectionOpen] = useState(false)
  const [deleteTarget, setDeleteTarget] = useState<QuoteSection | null>(null)
  const [deleteError, setDeleteError] = useState<string | null>(null)
  const [filter, setFilter] = useState<SectionsFilter>('active')

  function invalidate() {
    void queryClient.invalidateQueries({ queryKey: quoteConfigurationQueryKey })
  }

  const saveSettingsMut = useMutation({
    mutationFn: (next: Omit<QuoteSettings, 'updatedAt'>) =>
      updateQuoteSettings(next),
    onSuccess: invalidate,
  })

  const addSectionMut = useMutation({
    mutationFn: (input: InsertSectionInput) => insertQuoteSection(input),
    onSuccess: invalidate,
  })

  const updateSectionMut = useMutation({
    mutationFn: (args: { id: string; active: boolean }) =>
      updateQuoteSection({ id: args.id, active: args.active }),
    onSuccess: invalidate,
  })

  const reorderMut = useMutation({
    mutationFn: (orderedIds: string[]) => reorderQuoteSections(orderedIds),
    onSuccess: invalidate,
  })

  const deleteMut = useMutation({
    mutationFn: (id: string) => deleteQuoteSection(id),
    onSuccess: () => {
      setDeleteTarget(null)
      invalidate()
    },
  })

  const ordered = useMemo(
    () => (config ? sectionsInOrder(config) : []),
    [config],
  )
  const nextDisplayOrder = useMemo(() => {
    if (ordered.length === 0) return 1
    return Math.max(...ordered.map((s) => s.displayOrder)) + 1
  }, [ordered])

  const serviceCounts = useMemo(() => {
    const map: Record<string, number> = {}
    if (!config) return map
    for (const s of ordered) {
      map[s.id] = serviceCountForSection(config, s.id)
    }
    return map
  }, [config, ordered])

  const totalCount = ordered.length
  const activeCount = ordered.filter((s) => s.active).length
  const archivedCount = totalCount - activeCount

  const visibleSections = useMemo(() => {
    if (filter === 'active') return ordered.filter((s) => s.active)
    if (filter === 'archived') return ordered.filter((s) => !s.active)
    return ordered
  }, [ordered, filter])

  if (isLoading || !config) {
    return (
      <div data-testid="quote-config-page">
        <LoadingState
          message="Loading quote configuration…"
          testId="quote-config-loading"
        />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="quote-config-page">
        <ErrorState
          title="Could not load quote configuration"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="quote-config-error"
        />
      </div>
    )
  }

  function handleToggleActive(section: QuoteSection) {
    updateSectionMut.mutate({ id: section.id, active: !section.active })
  }

  /**
   * Move a section up/down within the currently-visible filtered list.
   * Hidden rows keep their relative positions in the global order; only
   * visible siblings swap with each other. Display order is then normalized
   * 1..N on the server so the resulting ordering is stable and predictable.
   */
  function handleMoveInFilter(id: string, direction: 'up' | 'down') {
    const visibleIds = visibleSections.map((s) => s.id)
    const vIdx = visibleIds.indexOf(id)
    if (vIdx === -1) return
    const neighborIdx = direction === 'up' ? vIdx - 1 : vIdx + 1
    if (neighborIdx < 0 || neighborIdx >= visibleIds.length) return
    const swappedVisible = [...visibleIds]
    ;[swappedVisible[vIdx], swappedVisible[neighborIdx]] = [
      swappedVisible[neighborIdx],
      swappedVisible[vIdx],
    ]
    const visibleSet = new Set(visibleIds)
    const queue = [...swappedVisible]
    const fullIds = ordered.map((s) =>
      visibleSet.has(s.id) ? (queue.shift() ?? s.id) : s.id,
    )
    reorderMut.mutate(fullIds)
  }

  function confirmDelete() {
    if (!deleteTarget) return
    setDeleteError(null)
    deleteMut.mutate(deleteTarget.id, {
      onError: (err) => {
        const { message, err: e } = queryErrorDetail(err)
        setDeleteError(e?.message ?? message ?? 'Unable to delete section.')
      },
    })
  }

  const { settings } = config

  return (
    <>
      <PageHeader
        title="Quote Configuration"
        description="Manage the Guest Quote page — global settings and the sections shown to stylists."
        actions={
          <button
            type="button"
            className="inline-flex items-center rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 shadow-sm hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-60"
            disabled
            title="Coming soon — will render the stylist-facing quote preview."
            data-testid="quote-config-preview"
          >
            Preview Quote Config
          </button>
        }
      />

      <QuoteSettingsCard
        settings={settings}
        onSave={(next) => saveSettingsMut.mutate(next)}
      />
      {saveSettingsMut.isError ? (
        <p
          className="-mt-6 mb-6 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
          role="alert"
          data-testid="quote-settings-error"
        >
          {queryErrorDetail(saveSettingsMut.error).err?.message ??
            'Unable to save settings.'}
        </p>
      ) : null}

      <div className="mb-3 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <div className="flex items-center gap-3">
            <h2 className="text-lg font-semibold text-slate-900">Sections</h2>
            <button
              type="button"
              onClick={() => setAddSectionOpen(true)}
              className="inline-flex items-center rounded-md bg-violet-600 px-3 py-1.5 text-sm font-medium text-white shadow-sm hover:bg-violet-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1"
              data-testid="quote-config-add-section"
            >
              Add Section
            </button>
          </div>
          <p className="mt-1 text-sm text-slate-600">
            Open a section to rename it or manage its services. Sections that share
            a summary label roll up together on saved quotes.
          </p>
        </div>
        <p
          className="text-xs text-slate-500"
          data-testid="quote-sections-counts"
        >
          {totalCount} total · {activeCount} active · {archivedCount} archived
        </p>
      </div>

      <div className="mb-3 flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div
          className="inline-flex rounded-md border border-slate-200 bg-white p-0.5 shadow-sm"
          role="tablist"
          aria-label="Filter sections"
          data-testid="quote-sections-filter"
        >
          {FILTER_OPTIONS.map((opt) => {
            const selected = filter === opt.id
            const count =
              opt.id === 'active'
                ? activeCount
                : opt.id === 'archived'
                  ? archivedCount
                  : totalCount
            return (
              <button
                key={opt.id}
                type="button"
                role="tab"
                aria-selected={selected}
                onClick={() => setFilter(opt.id)}
                className={
                  'inline-flex items-center gap-1.5 rounded px-3 py-1.5 text-sm font-medium transition focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 ' +
                  (selected
                    ? 'bg-violet-600 text-white shadow-sm'
                    : 'text-slate-700 hover:bg-slate-50')
                }
                data-testid={`quote-sections-filter-${opt.id}`}
              >
                <span>{opt.label}</span>
                <span
                  className={
                    'inline-flex min-w-[1.25rem] items-center justify-center rounded-full px-1.5 text-xs tabular-nums ' +
                    (selected
                      ? 'bg-white/20 text-white'
                      : 'bg-slate-100 text-slate-600')
                  }
                >
                  {count}
                </span>
              </button>
            )
          })}
        </div>
        <p className="text-xs text-slate-500" aria-live="polite">
          Showing {visibleSections.length} of {totalCount}
        </p>
      </div>

      {deleteError ? (
        <p
          className="mb-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
          role="alert"
        >
          {deleteError}
        </p>
      ) : null}

      {reorderMut.isError ? (
        <p
          className="mb-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
          role="alert"
        >
          {queryErrorDetail(reorderMut.error).err?.message ??
            'Unable to reorder sections.'}
        </p>
      ) : null}

      {visibleSections.length === 0 ? (
        <div
          className="rounded-lg border border-dashed border-slate-200 bg-white px-6 py-12 text-center"
          data-testid="quote-sections-empty"
        >
          <p className="text-sm font-medium text-slate-800">
            {totalCount === 0
              ? 'No sections yet.'
              : filter === 'archived'
                ? 'No archived sections.'
                : 'No sections match this filter.'}
          </p>
          <p className="mt-1 text-sm text-slate-600">
            {totalCount === 0 ? (
              <>
                Use <span className="font-medium">Add Section</span> above to
                create the first one.
              </>
            ) : filter === 'archived' ? (
              <>
                Archiving a section moves it here. It stays recoverable and is
                hidden from the stylist-facing quote.
              </>
            ) : (
              <>Switch the filter to see more sections.</>
            )}
          </p>
        </div>
      ) : (
        <QuoteSectionsTable
          sections={visibleSections}
          serviceCounts={serviceCounts}
          onMove={handleMoveInFilter}
          onToggleActive={handleToggleActive}
          onDelete={(section) => {
            setDeleteError(null)
            setDeleteTarget(section)
          }}
        />
      )}

      <AddSectionModal
        open={addSectionOpen}
        nextDisplayOrder={nextDisplayOrder}
        onClose={() => setAddSectionOpen(false)}
        onAdd={(input) => addSectionMut.mutate(input)}
      />

      <ConfirmDialog
        open={deleteTarget != null}
        title={
          deleteTarget ? `Delete "${deleteTarget.name}"?` : 'Delete section?'
        }
        description="This removes the section and all of its services. This cannot be undone."
        confirmLabel="Delete Section"
        tone="danger"
        onConfirm={confirmDelete}
        onClose={() => setDeleteTarget(null)}
        testId="quote-config-delete-dialog"
      />
    </>
  )
}
