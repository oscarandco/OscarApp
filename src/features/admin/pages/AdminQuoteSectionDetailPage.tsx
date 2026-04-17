import { useMutation, useQueryClient } from '@tanstack/react-query'
import { type FormEvent, useMemo, useState } from 'react'
import { Link, useNavigate, useParams } from 'react-router-dom'

import { ConfirmDialog } from '@/components/feedback/ConfirmDialog'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import {
  QuoteServiceDrawer,
  type QuoteServiceDrawerMode,
} from '@/features/admin/components/QuoteServiceDrawer'
import { QuoteServicesTable } from '@/features/admin/components/QuoteServicesTable'
import { ToggleField } from '@/features/admin/components/QuoteSettingsCard'
import {
  quoteConfigurationQueryKey,
  servicesForSection,
  useQuoteConfiguration,
} from '@/features/admin/hooks/useQuoteConfiguration'
import type {
  QuoteSection,
  QuoteService,
} from '@/features/admin/types/quoteConfiguration'
import {
  deleteQuoteSection,
  deleteQuoteService,
  reorderQuoteServicesInSection,
  saveQuoteService,
  updateQuoteSection,
  type UpdateSectionInput,
} from '@/lib/quoteConfigurationApi'
import { queryErrorDetail } from '@/lib/queryError'

export function AdminQuoteSectionDetailPage() {
  const { sectionId = '' } = useParams<{ sectionId: string }>()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const { data: config, isLoading, isError, error, refetch } =
    useQuoteConfiguration()

  const section = useMemo(
    () => config?.sections.find((s) => s.id === sectionId) ?? null,
    [config, sectionId],
  )

  const services = useMemo(
    () => (config ? servicesForSection(config, sectionId) : []),
    [config, sectionId],
  )

  const [drawerOpen, setDrawerOpen] = useState(false)
  const [drawerMode, setDrawerMode] = useState<QuoteServiceDrawerMode>('create')
  const [drawerService, setDrawerService] = useState<QuoteService | null>(null)
  const [serviceSaveError, setServiceSaveError] = useState<string | null>(null)

  const [confirmDeleteSection, setConfirmDeleteSection] = useState(false)
  const [confirmDeleteService, setConfirmDeleteService] =
    useState<QuoteService | null>(null)
  const [deleteServiceError, setDeleteServiceError] = useState<string | null>(null)
  const [deleteSectionError, setDeleteSectionError] = useState<string | null>(null)

  function invalidate() {
    void queryClient.invalidateQueries({ queryKey: quoteConfigurationQueryKey })
  }

  const updateSectionMut = useMutation({
    mutationFn: (args: UpdateSectionInput) => updateQuoteSection(args),
    onSuccess: invalidate,
  })

  const deleteSectionMut = useMutation({
    mutationFn: (id: string) => deleteQuoteSection(id),
    onSuccess: () => {
      invalidate()
      navigate('/app/admin/quotes')
    },
  })

  const saveServiceMut = useMutation({
    mutationFn: (args: {
      id: string | null
      service: Partial<QuoteService> & { name: string; sectionId: string }
    }) => saveQuoteService(args),
    onSuccess: invalidate,
  })

  const moveServiceMut = useMutation({
    mutationFn: (orderedIds: string[]) =>
      reorderQuoteServicesInSection(sectionId, orderedIds),
    onSuccess: invalidate,
  })

  const deleteServiceMut = useMutation({
    mutationFn: (id: string) => deleteQuoteService(id),
    onSuccess: () => {
      setConfirmDeleteService(null)
      setDrawerOpen(false)
      invalidate()
    },
  })

  if (isLoading || !config) {
    return (
      <div data-testid="quote-section-page">
        <LoadingState
          message="Loading section…"
          testId="quote-section-loading"
        />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="quote-section-page">
        <ErrorState
          title="Could not load section"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="quote-section-error"
        />
      </div>
    )
  }

  if (!section) {
    return (
      <>
        <div className="mb-3">
          <Link
            to="/app/admin/quotes"
            className="text-sm font-medium text-violet-700 hover:text-violet-900"
          >
            ← Back to Quote Configuration
          </Link>
        </div>
        <PageHeader
          title="Section not found"
          description="This section may have been deleted."
        />
        <div className="rounded-lg border border-dashed border-slate-200 bg-white px-6 py-12 text-center">
          <p className="text-sm font-medium text-slate-800">Section not found.</p>
          <Link
            to="/app/admin/quotes"
            className="mt-4 inline-flex items-center rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
          >
            Back to Quote Configuration
          </Link>
        </div>
      </>
    )
  }

  const currentSection = section

  function confirmDeleteSectionNow() {
    setDeleteSectionError(null)
    deleteSectionMut.mutate(currentSection.id, {
      onError: (err) => {
        setDeleteSectionError(
          queryErrorDetail(err).err?.message ?? 'Unable to delete section.',
        )
      },
    })
  }

  function openAddService() {
    setServiceSaveError(null)
    setDrawerMode('create')
    setDrawerService(null)
    setDrawerOpen(true)
  }

  function openEditService(svc: QuoteService) {
    setServiceSaveError(null)
    setDrawerMode('edit')
    setDrawerService(svc)
    setDrawerOpen(true)
  }

  function openDuplicateService(svc: QuoteService) {
    setServiceSaveError(null)
    setDrawerMode('duplicate')
    setDrawerService(svc)
    setDrawerOpen(true)
  }

  function handleServiceDrawerSubmit(
    payload: Partial<QuoteService> & { name: string; sectionId: string },
    ctx: { mode: QuoteServiceDrawerMode; existingId: string | null },
  ) {
    setServiceSaveError(null)
    // The drawer closes itself on submit; if the server rejects the payload,
    // surface the error on the page below the services table.
    const id = ctx.mode === 'edit' ? ctx.existingId : null
    saveServiceMut.mutate(
      { id, service: payload },
      {
        onError: (err) => {
          setServiceSaveError(
            queryErrorDetail(err).err?.message ?? 'Unable to save service.',
          )
        },
      },
    )
  }

  function handleServiceArchive(svc: QuoteService) {
    // Persist archive/unarchive by round-tripping the full service through
    // save_quote_service so we re-use its validation pipeline rather than
    // writing a separate narrow mutation.
    saveServiceMut.mutate({
      id: svc.id,
      service: {
        ...svc,
        active: !svc.active,
      },
    })
  }

  function handleServiceMoveInFilter(id: string, direction: 'up' | 'down') {
    const orderedIds = services.map((s) => s.id)
    const idx = orderedIds.indexOf(id)
    if (idx === -1) return
    const swap = direction === 'up' ? idx - 1 : idx + 1
    if (swap < 0 || swap >= orderedIds.length) return
    const next = [...orderedIds]
    ;[next[idx], next[swap]] = [next[swap], next[idx]]
    moveServiceMut.mutate(next)
  }

  function confirmDeleteServiceNow() {
    if (!confirmDeleteService) return
    setDeleteServiceError(null)
    deleteServiceMut.mutate(confirmDeleteService.id, {
      onError: (err) => {
        setDeleteServiceError(
          queryErrorDetail(err).err?.message ?? 'Unable to delete service.',
        )
      },
    })
  }

  const canDeleteSection = !currentSection.usedInSavedQuotes

  return (
    <>
      <div className="mb-3">
        <Link
          to="/app/admin/quotes"
          className="text-sm font-medium text-violet-700 hover:text-violet-900"
          data-testid="quote-section-back"
        >
          ← Back to Quote Configuration
        </Link>
      </div>
      <PageHeader
        title={currentSection.name}
        description={`Section detail · Summary label: ${
          currentSection.summaryLabel || currentSection.name
        }`}
        actions={
          <>
            <span
              className={`inline-flex items-center rounded-full px-2 py-1 text-xs font-medium ring-1 ${
                currentSection.active
                  ? 'bg-emerald-50 text-emerald-700 ring-emerald-200'
                  : 'bg-slate-100 text-slate-600 ring-slate-200'
              }`}
            >
              {currentSection.active ? 'Active' : 'Archived'}
            </span>
            <button
              type="button"
              onClick={openAddService}
              className="inline-flex items-center rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1"
              data-testid="quote-section-add-service"
            >
              Add Service
            </button>
          </>
        }
      />

      {/*
        Key the form by the section's id + updatedAt so local edits snap back
        to the refetched canonical values (e.g. after archive/unarchive). This
        avoids a useEffect → setState sync and keeps the form simple.
      */}
      <SectionDetailsForm
        key={`${currentSection.id}:${currentSection.updatedAt}`}
        section={currentSection}
        canDelete={canDeleteSection}
        isSaving={updateSectionMut.isPending}
        deleteSectionError={deleteSectionError}
        onArchive={() =>
          updateSectionMut.mutate({
            id: currentSection.id,
            active: !currentSection.active,
          })
        }
        onDelete={() => setConfirmDeleteSection(true)}
        onSave={(patch, cb) =>
          updateSectionMut.mutate(
            { id: currentSection.id, ...patch },
            {
              onSuccess: cb.onSuccess,
              onError: (err) => {
                cb.onError(
                  queryErrorDetail(err).err?.message ??
                    'Unable to save section.',
                )
              },
            },
          )
        }
      />

      <div className="mb-3 flex flex-col gap-1 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <h2 className="text-lg font-semibold text-slate-900">Services</h2>
          <p className="text-sm text-slate-600">
            Manage the services shown in this section. Edit opens a drawer on the right.
          </p>
        </div>
        <p className="text-xs text-slate-500">
          {services.length} service{services.length === 1 ? '' : 's'} ·{' '}
          {services.filter((s) => s.active).length} active
        </p>
      </div>

      {deleteServiceError ? (
        <p
          className="mb-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
          role="alert"
        >
          {deleteServiceError}
        </p>
      ) : null}

      {moveServiceMut.isError ? (
        <p
          className="mb-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
          role="alert"
        >
          {queryErrorDetail(moveServiceMut.error).err?.message ??
            'Unable to reorder services.'}
        </p>
      ) : null}

      {serviceSaveError ? (
        <p
          className="mb-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
          role="alert"
          data-testid="quote-service-save-error"
        >
          {serviceSaveError}
        </p>
      ) : null}

      <QuoteServicesTable
        services={services}
        onEdit={openEditService}
        onDuplicate={openDuplicateService}
        onMove={handleServiceMoveInFilter}
        onToggleActive={handleServiceArchive}
        onDelete={(svc) => {
          setDeleteServiceError(null)
          setConfirmDeleteService(svc)
        }}
      />

      <QuoteServiceDrawer
        open={drawerOpen}
        mode={drawerMode}
        sectionId={currentSection.id}
        existingService={drawerService}
        onClose={() => setDrawerOpen(false)}
        onSubmit={handleServiceDrawerSubmit}
        onArchive={handleServiceArchive}
        onDelete={(svc) => {
          setDeleteServiceError(null)
          setConfirmDeleteService(svc)
        }}
      />

      <ConfirmDialog
        open={confirmDeleteSection}
        title={`Delete "${currentSection.name}"?`}
        description="This removes the section and all of its services. This cannot be undone."
        confirmLabel="Delete Section"
        tone="danger"
        onConfirm={confirmDeleteSectionNow}
        onClose={() => setConfirmDeleteSection(false)}
        testId="quote-section-delete-dialog"
      />

      <ConfirmDialog
        open={confirmDeleteService != null}
        title={
          confirmDeleteService
            ? `Delete "${confirmDeleteService.name}"?`
            : 'Delete service?'
        }
        description="This removes the service and its options. This cannot be undone."
        confirmLabel="Delete Service"
        tone="danger"
        onConfirm={confirmDeleteServiceNow}
        onClose={() => setConfirmDeleteService(null)}
        testId="quote-service-delete-dialog"
      />
    </>
  )
}

type SectionDetailsFormProps = {
  section: QuoteSection
  canDelete: boolean
  isSaving: boolean
  deleteSectionError: string | null
  onSave: (
    patch: {
      name: string
      summaryLabel: string
      displayOrder: number
      active: boolean
      sectionHelpText: string | null
    },
    cb: { onSuccess: () => void; onError: (msg: string) => void },
  ) => void
  onArchive: () => void
  onDelete: () => void
}

/**
 * Editable card for a single quote section. The parent keys this component by
 * `section.id + section.updatedAt` so local state is always derived from the
 * latest loaded row without needing a useEffect → setState sync.
 */
function SectionDetailsForm({
  section,
  canDelete,
  isSaving,
  deleteSectionError,
  onSave,
  onArchive,
  onDelete,
}: SectionDetailsFormProps) {
  const [name, setName] = useState(section.name)
  const [summaryLabel, setSummaryLabel] = useState(section.summaryLabel)
  const [displayOrder, setDisplayOrder] = useState<string>(
    String(section.displayOrder),
  )
  const [active, setActive] = useState<boolean>(section.active)
  const [helpText, setHelpText] = useState<string>(section.sectionHelpText ?? '')
  const [saveError, setSaveError] = useState<string | null>(null)
  const [justSaved, setJustSaved] = useState(false)

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    setSaveError(null)
    const trimmedName = name.trim()
    if (trimmedName === '') {
      setSaveError('Section Name is required.')
      return
    }
    const order = Number(displayOrder)
    if (!Number.isFinite(order)) {
      setSaveError('Display Order must be a number.')
      return
    }
    onSave(
      {
        name: trimmedName,
        summaryLabel: summaryLabel.trim() || trimmedName,
        displayOrder: Math.trunc(order),
        active,
        sectionHelpText: helpText.trim() === '' ? null : helpText.trim(),
      },
      {
        onSuccess: () => {
          setJustSaved(true)
          window.setTimeout(() => setJustSaved(false), 2000)
        },
        onError: (msg) => setSaveError(msg),
      },
    )
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="mb-8 rounded-lg border border-slate-200 bg-white p-5 shadow-sm"
      data-testid="quote-section-details-card"
    >
      <div className="mb-4">
        <h2 className="text-lg font-semibold text-slate-900">Section Details</h2>
        <p className="mt-1 text-sm text-slate-600">
          The summary label is shown in the saved quote summary footer; sections
          that share a label are grouped together.
        </p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div>
          <label htmlFor="sec-name" className="block text-sm font-medium text-slate-700">
            Section Name <span className="text-rose-600">*</span>
          </label>
          <input
            id="sec-name"
            type="text"
            required
            value={name}
            onChange={(e) => setName(e.target.value)}
            className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
            data-testid="quote-section-name"
          />
        </div>
        <div>
          <label
            htmlFor="sec-summary-label"
            className="block text-sm font-medium text-slate-700"
          >
            Summary Label
          </label>
          <input
            id="sec-summary-label"
            type="text"
            value={summaryLabel}
            onChange={(e) => setSummaryLabel(e.target.value)}
            className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
            data-testid="quote-section-summary-label"
          />
        </div>
        <div>
          <label htmlFor="sec-order" className="block text-sm font-medium text-slate-700">
            Display Order
          </label>
          <input
            id="sec-order"
            type="number"
            value={displayOrder}
            onChange={(e) => setDisplayOrder(e.target.value)}
            className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
            data-testid="quote-section-display-order"
          />
        </div>
        <ToggleField
          id="sec-active"
          label="Active"
          checked={active}
          onChange={setActive}
          testId="quote-section-active"
        />
        <div className="sm:col-span-2">
          <label htmlFor="sec-help-text" className="block text-sm font-medium text-slate-700">
            Section Help Text
          </label>
          <textarea
            id="sec-help-text"
            rows={2}
            value={helpText}
            onChange={(e) => setHelpText(e.target.value)}
            className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
            data-testid="quote-section-help-text"
          />
        </div>
      </div>

      {saveError ? (
        <p
          className="mt-4 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
          role="alert"
        >
          {saveError}
        </p>
      ) : null}

      <div className="mt-5 flex flex-col gap-2 border-t border-slate-100 pt-4 sm:flex-row sm:items-center sm:justify-between">
        <div className="flex flex-wrap items-center gap-2">
          <button
            type="button"
            onClick={onArchive}
            className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
            data-testid="quote-section-archive"
          >
            {section.active ? 'Archive Section' : 'Unarchive Section'}
          </button>
          <button
            type="button"
            disabled={!canDelete}
            onClick={onDelete}
            title={
              canDelete
                ? 'Delete section'
                : 'Section has been used in saved quotes and cannot be deleted.'
            }
            className="rounded-md border border-rose-200 bg-white px-3 py-2 text-sm font-medium text-rose-700 shadow-sm hover:bg-rose-50 disabled:cursor-not-allowed disabled:opacity-40"
            data-testid="quote-section-delete"
          >
            Delete Section
          </button>
        </div>
        <div className="flex items-center justify-end gap-3">
          {justSaved ? (
            <span className="text-xs font-medium text-emerald-600">Saved</span>
          ) : null}
          <button
            type="submit"
            disabled={isSaving}
            className="inline-flex items-center rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1 disabled:cursor-not-allowed disabled:opacity-60"
            data-testid="quote-section-save"
          >
            {isSaving ? 'Saving…' : 'Save Section'}
          </button>
        </div>
      </div>
      {deleteSectionError ? (
        <p
          className="mt-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
          role="alert"
        >
          {deleteSectionError}
        </p>
      ) : null}
    </form>
  )
}
