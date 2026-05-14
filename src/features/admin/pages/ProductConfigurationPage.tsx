import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useRef, useState } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import type { ProductConfigurationBundle } from '@/features/admin/hooks/useProductConfiguration'
import { useProductConfiguration } from '@/features/admin/hooks/useProductConfiguration'
import type { ProductMasterRow } from '@/features/admin/types/productConfiguration'
import {
  deactivateProductMaster,
  insertProductMaster,
  updateProductMaster,
  type ProductMasterUpdatePayload,
} from '@/lib/productMasterApi'
import { queryErrorDetail } from '@/lib/queryError'

/**
 * `YYYY-MM-DD HH:mm` in Pacific/Auckland (NZ display time) for placeholder product
 * descriptions. Prefixing the description guarantees lexical sort after creation
 * roughly matches creation order, which helps even before we apply the
 * "recently created first" client sort.
 */
function nzDateTimePrefix(d: Date = new Date()): string {
  const parts = new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Pacific/Auckland',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(d)
  const get = (t: Intl.DateTimeFormatPartTypes) =>
    parts.find((p) => p.type === t)?.value ?? ''
  return `${get('year')}-${get('month')}-${get('day')} ${get('hour')}:${get('minute')}`
}

type StatusFilter = 'all' | 'active' | 'inactive'

type ProductFormDraft = {
  id: string
  product_description: string
  system_type: string
  product_type: string
  is_active: boolean
}

/**
 * Allowed System type values, in the order they appear in the editor dropdown
 * and the page-level filter. These mirror the salon's reporting categories.
 */
const SYSTEM_TYPE_OPTIONS = [
  'Retail',
  'Service',
  'Unclassified',
  'Voucher',
] as const

/**
 * Allowed Product type values, in the order they appear in the editor dropdown
 * and the page-level filter. `-` is the explicit placeholder for "none / N/A".
 */
const PRODUCT_TYPE_OPTIONS = ['Professional Product', 'Retail Product', '-'] as const

/**
 * Map an existing `product_type` value into the editor dropdown space. Blank /
 * null is shown as `-` because that's its canonical display per the allowed list.
 * Non-blank values that don't match an allowed option are returned as-is so the
 * editor can render them as an extra option without silently rewriting data.
 */
function productTypeForEditor(v: string | null | undefined): string {
  const s = String(v ?? '').trim()
  if (s === '') return '-'
  return s
}

/**
 * Map an existing `system_type` value into the editor dropdown space. We keep
 * blanks as `''` (rendered as an extra "(unset)" option) rather than coercing
 * them to one of the allowed values, because there is no canonical "none"
 * synonym for system_type (`-` isn't valid there).
 */
function systemTypeForEditor(v: string | null | undefined): string {
  return String(v ?? '').trim()
}

function draftFromRow(row: ProductMasterRow): ProductFormDraft {
  return {
    id: row.id,
    product_description: row.product_description,
    system_type: systemTypeForEditor(row.system_type),
    product_type: productTypeForEditor(row.product_type),
    is_active: row.is_active,
  }
}

/** Sentinel ID for the in-memory draft product. Database UUIDs never collide with this. */
const DRAFT_PRODUCT_ID = '__unsaved_draft__'

/** Default field values for a new in-memory draft product. */
function makeNewDraftProduct(): ProductMasterRow {
  const now = new Date().toISOString()
  return {
    id: DRAFT_PRODUCT_ID,
    product_description: `${nzDateTimePrefix()} New product`,
    system_type: 'Service',
    product_type: '-',
    is_active: true,
    created_at: now,
    updated_at: now,
  }
}

function isDraftProduct(p: ProductMasterRow | null | undefined): boolean {
  return p != null && p.id === DRAFT_PRODUCT_ID
}

function ProductListRow({
  row,
  active,
  unsaved,
  onSelect,
}: {
  row: ProductMasterRow
  active: boolean
  unsaved: boolean
  onSelect: (id: string) => void
}) {
  const sub = [row.system_type, row.product_type].filter(Boolean).join(' · ')
  return (
    <li>
      <button
        type="button"
        onClick={() => onSelect(row.id)}
        className={`flex w-full items-center justify-between gap-2 rounded-lg border px-3 py-2.5 text-left text-sm transition ${
          active
            ? 'border-violet-300 bg-violet-50 text-violet-950'
            : unsaved
              ? 'border-amber-200 bg-amber-50/60 text-amber-950 hover:border-amber-300 hover:bg-amber-50'
              : 'border-transparent bg-slate-50/80 text-slate-800 hover:border-slate-200 hover:bg-white'
        }`}
      >
        <span className="block min-w-0 flex-1 truncate text-left">
          <span className="font-medium text-slate-900">{row.product_description}</span>
          {sub ? (
            <span className="block truncate text-xs font-normal text-slate-500">{sub}</span>
          ) : null}
        </span>
        <span
          className={`shrink-0 text-xs font-medium ${
            unsaved
              ? 'text-amber-700'
              : row.is_active
                ? 'text-emerald-700'
                : 'text-slate-400'
          }`}
        >
          {unsaved ? 'Unsaved' : row.is_active ? 'Active' : 'Inactive'}
        </span>
      </button>
    </li>
  )
}

export function ProductConfigurationPage() {
  const queryClient = useQueryClient()
  const { data, isLoading, isError, error, refetch } = useProductConfiguration()

  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('active')
  const [systemTypeFilter, setSystemTypeFilter] = useState('')
  const [productTypeFilter, setProductTypeFilter] = useState('')
  const [draft, setDraft] = useState<ProductFormDraft | null>(null)
  /** IDs created (saved) in this session, most-recent first. Sorted to top of left list. */
  const [recentlyCreatedIds, setRecentlyCreatedIds] = useState<string[]>([])
  /**
   * Local-only draft product. Lives in component state until the user clicks
   * Save changes. The DB row is only inserted on save.
   */
  const [draftProduct, setDraftProduct] = useState<ProductMasterRow | null>(null)
  /** When set, the description input is focused after the matching product is selected. */
  const [pendingFocusId, setPendingFocusId] = useState<string | null>(null)
  const descriptionInputRef = useRef<HTMLInputElement | null>(null)

  const products = data?.products ?? []

  /**
   * Filter dropdown options for System type. Always offer the canonical list
   * first (in the prescribed order), then append any legacy values still
   * present in the data so they remain filterable.
   */
  const systemTypeOptions = useMemo(() => {
    const allowed = new Set<string>(SYSTEM_TYPE_OPTIONS)
    const extras = new Set<string>()
    for (const p of products) {
      const s = (p.system_type ?? '').trim()
      if (s && !allowed.has(s)) extras.add(s)
    }
    const tail = [...extras].sort((a, b) =>
      a.localeCompare(b, undefined, { sensitivity: 'base' }),
    )
    return [...SYSTEM_TYPE_OPTIONS, ...tail]
  }, [products])

  /**
   * Filter dropdown options for Product type. Same approach as System type:
   * canonical list first, legacy values appended at the end.
   */
  const productTypeOptions = useMemo(() => {
    const allowed = new Set<string>(PRODUCT_TYPE_OPTIONS)
    const extras = new Set<string>()
    for (const p of products) {
      const s = (p.product_type ?? '').trim()
      if (s && !allowed.has(s)) extras.add(s)
    }
    const tail = [...extras].sort((a, b) =>
      a.localeCompare(b, undefined, { sensitivity: 'base' }),
    )
    return [...PRODUCT_TYPE_OPTIONS, ...tail]
  }, [products])

  const filteredProducts = useMemo(() => {
    const q = search.trim().toLowerCase()
    const recentSet = new Set(recentlyCreatedIds)
    const matches = products.filter((p) => {
      // Always surface products created in this session — they ignore filters so
      // the user can immediately rename/classify them in the left list.
      if (recentSet.has(p.id)) return true
      if (statusFilter === 'active' && !p.is_active) return false
      if (statusFilter === 'inactive' && p.is_active) return false
      if (systemTypeFilter !== '') {
        if ((p.system_type ?? '').trim() !== systemTypeFilter) return false
      }
      if (productTypeFilter !== '') {
        if ((p.product_type ?? '').trim() !== productTypeFilter) return false
      }
      if (!q) return true
      const hay =
        `${p.product_description} ${p.system_type ?? ''} ${p.product_type ?? ''}`.toLowerCase()
      return hay.includes(q)
    })
    let sorted: ProductMasterRow[] = matches
    if (recentlyCreatedIds.length > 0) {
      const recentRank = new Map<string, number>()
      recentlyCreatedIds.forEach((id, i) => recentRank.set(id, i))
      const recents: ProductMasterRow[] = []
      const rest: ProductMasterRow[] = []
      for (const p of matches) {
        if (recentRank.has(p.id)) recents.push(p)
        else rest.push(p)
      }
      recents.sort((a, b) => (recentRank.get(a.id) ?? 0) - (recentRank.get(b.id) ?? 0))
      sorted = [...recents, ...rest]
    }
    // Unsaved draft always sits at the very top so it can't be lost behind filters.
    if (draftProduct) return [draftProduct, ...sorted]
    return sorted
  }, [
    products,
    search,
    statusFilter,
    systemTypeFilter,
    productTypeFilter,
    recentlyCreatedIds,
    draftProduct,
  ])

  const selected = useMemo<ProductMasterRow | null>(() => {
    if (selectedId === DRAFT_PRODUCT_ID && draftProduct) return draftProduct
    return products.find((p) => p.id === selectedId) ?? null
  }, [products, selectedId, draftProduct])

  useEffect(() => {
    if (!selected) {
      setDraft(null)
      return
    }
    setDraft(draftFromRow(selected))
  }, [selected])

  useEffect(() => {
    if (filteredProducts.length === 0) {
      if (selectedId !== null) setSelectedId(null)
      return
    }
    if (selectedId != null && filteredProducts.some((p) => p.id === selectedId)) return
    setSelectedId(filteredProducts[0].id)
  }, [filteredProducts, selectedId])

  const isDraftSelected = selectedId === DRAFT_PRODUCT_ID && draftProduct != null

  const dirty = useMemo(() => {
    if (!selected || !draft) return false
    // Drafts have no DB row to compare against — they're inherently "dirty"
    // (the Save changes button must be enabled even before the user types).
    if (isDraftProduct(selected)) return true
    const base = draftFromRow(selected)
    const keys: (keyof ProductFormDraft)[] = [
      'product_description',
      'system_type',
      'product_type',
      'is_active',
    ]
    for (const k of keys) {
      const a = draft[k]
      const b = base[k]
      if (k === 'is_active') {
        if (a !== b) return true
        continue
      }
      const an = typeof a === 'string' ? a.trim() : a
      const bn = typeof b === 'string' ? b.trim() : b
      if (an !== bn) return true
    }
    return false
  }, [selected, draft])

  /** Warn before page unload while an unsaved draft exists. */
  useEffect(() => {
    if (draftProduct == null) return
    const handler = (e: BeforeUnloadEvent) => {
      e.preventDefault()
      e.returnValue = ''
    }
    window.addEventListener('beforeunload', handler)
    return () => window.removeEventListener('beforeunload', handler)
  }, [draftProduct])

  /**
   * Replace the page-level cache after a successful insert/update so the new row
   * is visible immediately and the auto-select effect doesn't bounce selection
   * to a stale first item while invalidation refetches in the background.
   */
  function patchCacheWithRow(row: ProductMasterRow) {
    queryClient.setQueryData<ProductConfigurationBundle | undefined>(
      ['product-configuration'],
      (old) => {
        if (!old) return { products: [row] }
        const idx = old.products.findIndex((p) => p.id === row.id)
        if (idx === -1) return { products: [row, ...old.products] }
        const next = old.products.slice()
        next[idx] = row
        return { products: next }
      },
    )
  }

  const saveMut = useMutation({
    mutationFn: async (): Promise<ProductMasterRow | null> => {
      if (!draft) return null
      // Saving a draft → INSERT a brand new product_master row with the draft fields.
      if (draft.id === DRAFT_PRODUCT_ID) {
        return await insertProductMaster({
          product_description: draft.product_description,
          system_type: draft.system_type || null,
          product_type: draft.product_type || null,
          is_active: draft.is_active,
        })
      }
      // Saving an existing product → UPDATE in place (unchanged behaviour).
      const payload: ProductMasterUpdatePayload = {
        id: draft.id,
        product_description: draft.product_description,
        system_type: draft.system_type || null,
        product_type: draft.product_type || null,
        is_active: draft.is_active,
      }
      await updateProductMaster(payload)
      return null
    },
    onSuccess: (insertedRow) => {
      if (insertedRow) {
        patchCacheWithRow(insertedRow)
        setRecentlyCreatedIds((prev) =>
          prev.includes(insertedRow.id) ? prev : [insertedRow.id, ...prev],
        )
        setDraftProduct(null)
        setSelectedId(insertedRow.id)
      }
      void queryClient.invalidateQueries({ queryKey: ['product-configuration'] })
    },
  })

  /** Promote `draftProduct` to selection (creating it first if absent). */
  function startOrFocusDraft() {
    if (draftProduct == null) {
      const next = makeNewDraftProduct()
      setDraftProduct(next)
      setSelectedId(DRAFT_PRODUCT_ID)
      setPendingFocusId(DRAFT_PRODUCT_ID)
      return
    }
    // Existing draft — just refocus, never make a second one.
    setSelectedId(DRAFT_PRODUCT_ID)
    setPendingFocusId(DRAFT_PRODUCT_ID)
  }

  /**
   * Guarded selection — confirms before abandoning an unsaved draft. Use this
   * everywhere the user changes the selected row (left list, Create button).
   */
  function attemptSelectId(nextId: string) {
    if (nextId === selectedId) return
    if (
      draftProduct != null &&
      selectedId === DRAFT_PRODUCT_ID &&
      nextId !== DRAFT_PRODUCT_ID
    ) {
      const ok = window.confirm('You have an unsaved product. Discard changes?')
      if (!ok) return
      setDraftProduct(null)
    }
    setSelectedId(nextId)
  }

  function handleCreateClick() {
    startOrFocusDraft()
  }

  const deleteMut = useMutation({
    mutationFn: async (id: string) => {
      await deactivateProductMaster(id)
    },
    onSuccess: (_void, id) => {
      // Reflect deactivation immediately so the active filter hides it without
      // waiting on the refetch to complete.
      queryClient.setQueryData<ProductConfigurationBundle | undefined>(
        ['product-configuration'],
        (old) => {
          if (!old) return old
          return {
            products: old.products.map((p) =>
              p.id === id ? { ...p, is_active: false } : p,
            ),
          }
        },
      )
      // Drop deactivated row from the recently-created pin so the active filter can hide it.
      setRecentlyCreatedIds((prev) => prev.filter((x) => x !== id))
      void queryClient.invalidateQueries({ queryKey: ['product-configuration'] })
    },
  })

  function handleDeleteClick() {
    if (!selected) return
    // Draft → throw away local state, no DB call.
    if (isDraftProduct(selected)) {
      setDraftProduct(null)
      // Pick the next non-draft entry in the visible list as the new selection.
      const fallback = filteredProducts.find((p) => p.id !== DRAFT_PRODUCT_ID)
      setSelectedId(fallback ? fallback.id : null)
      return
    }
    const ok = window.confirm(
      'Delete this product? This will deactivate it and exclude it from future matching, but historical reporting data will remain unchanged.',
    )
    if (!ok) return
    void deleteMut.mutateAsync(selected.id)
  }

  // Focus the description input once the just-created product is selected and
  // its draft has populated the input. Select-all so the user can immediately
  // rename the placeholder description.
  useEffect(() => {
    if (pendingFocusId == null) return
    if (!selected || selected.id !== pendingFocusId) return
    if (!draft || draft.id !== pendingFocusId) return
    const el = descriptionInputRef.current
    if (el == null) return
    el.focus()
    try {
      el.select()
    } catch {
      // ignore focus/select errors in non-DOM environments
    }
    setPendingFocusId(null)
  }, [pendingFocusId, selected, draft])

  if (isLoading) {
    return (
      <div data-testid="product-config-page">
        <LoadingState message="Loading products…" testId="product-config-loading" />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="product-config-page">
        <ErrorState
          title="Could not load products"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="product-config-error"
        />
      </div>
    )
  }

  return (
    <div
      data-testid="product-config-page"
      className="flex min-h-0 w-full flex-col lg:h-[calc(100dvh-7.5rem)] lg:min-h-0 lg:overflow-hidden"
    >
      <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
        <div className="shrink-0 border-b border-slate-200/80 bg-slate-50/90 py-2 pl-2 pr-4 sm:py-2.5 sm:pl-3 sm:pr-6">
          <div className="rounded-xl border border-slate-200 bg-white p-3 shadow-sm sm:p-4">
            <div className="flex flex-wrap items-end gap-x-4 gap-y-3">
              <div className="w-full min-w-0 md:min-w-[14rem] md:flex-[2] md:basis-[min(100%,22rem)]">
                <label
                  className="block text-xs font-medium text-slate-600"
                  htmlFor="product-filter-search"
                >
                  Search
                </label>
                <input
                  id="product-filter-search"
                  type="search"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder="Description, system type, or product type…"
                  autoComplete="off"
                  className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                />
              </div>
              <div className="w-full shrink-0 sm:w-44">
                <label
                  className="block text-xs font-medium text-slate-600"
                  htmlFor="product-filter-status"
                >
                  Status
                </label>
                <select
                  id="product-filter-status"
                  value={statusFilter}
                  onChange={(e) => setStatusFilter(e.target.value as StatusFilter)}
                  className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                >
                  <option value="all">All</option>
                  <option value="active">Active</option>
                  <option value="inactive">Inactive</option>
                </select>
              </div>
              <div className="w-full shrink-0 sm:w-44">
                <label
                  className="block text-xs font-medium text-slate-600"
                  htmlFor="product-filter-system-type"
                >
                  System type
                </label>
                <select
                  id="product-filter-system-type"
                  value={systemTypeFilter}
                  onChange={(e) => setSystemTypeFilter(e.target.value)}
                  className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                >
                  <option value="">All</option>
                  {systemTypeOptions.map((t) => (
                    <option key={t} value={t}>
                      {t}
                    </option>
                  ))}
                </select>
              </div>
              <div className="w-full shrink-0 sm:w-44">
                <label
                  className="block text-xs font-medium text-slate-600"
                  htmlFor="product-filter-product-type"
                >
                  Product type
                </label>
                <select
                  id="product-filter-product-type"
                  value={productTypeFilter}
                  onChange={(e) => setProductTypeFilter(e.target.value)}
                  className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                >
                  <option value="">All</option>
                  {productTypeOptions.map((t) => (
                    <option key={t} value={t}>
                      {t}
                    </option>
                  ))}
                </select>
              </div>
            </div>
          </div>
        </div>

        <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-hidden pb-4 pl-2 pr-4 pt-2 sm:pl-3 sm:pr-6 lg:flex-row lg:pt-3">
          <aside className="flex min-h-0 w-full shrink-0 flex-col border-b border-slate-200 bg-white px-3 py-3 shadow-sm max-h-[min(46vh,26rem)] sm:px-4 lg:max-h-none lg:h-full lg:w-72 lg:overflow-hidden lg:rounded-lg lg:border lg:border-slate-200 lg:py-4 lg:shadow-sm">
            <button
              type="button"
              onClick={handleCreateClick}
              className="w-full shrink-0 rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:opacity-50"
              data-testid="product-config-create-btn"
            >
              Create new product
            </button>
            {draftProduct != null && !isDraftSelected ? (
              <p className="mt-2 shrink-0 text-xs text-amber-700">
                Save or discard the current draft first.
              </p>
            ) : null}
            <div className="mt-3 min-h-0 flex-1 overflow-y-auto pr-0.5">
              {filteredProducts.length === 0 ? (
                <p className="text-sm text-slate-500">No products match your filters.</p>
              ) : (
                <ul className="space-y-1 pb-2">
                  {filteredProducts.map((p) => (
                    <ProductListRow
                      key={p.id}
                      row={p}
                      active={p.id === selectedId}
                      unsaved={p.id === DRAFT_PRODUCT_ID}
                      onSelect={attemptSelectId}
                    />
                  ))}
                </ul>
              )}
            </div>
          </aside>

          <div className="min-h-0 min-w-0 flex-1 overflow-y-auto pb-6 pt-0">
            <PageHeader
              title="Product Configuration"
              description="Products are matched to imported Sales Daily Sheets lines by exact product description. The System type and Product type selected here determine how each line is classified for commission, payroll summaries, sales reporting, and KPI reporting. Changes affect future rebuilds and imports, so use Rebuild reporting data after updating product classifications."
            />

            <div
              className="mb-6 w-full rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950"
              role="status"
            >
              <span className="font-medium">Important: </span>
              Renaming a product description, or deactivating a product, can change which
              imported sale lines match it next time data is imported or rebuilt.
            </div>

            <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
              {!selected || !draft ? (
                <p className="text-sm text-slate-600">Select a product, or create one.</p>
              ) : (
                <form
                  className="space-y-6"
                  onSubmit={(e) => {
                    e.preventDefault()
                    void saveMut.mutateAsync()
                  }}
                >
                  <div>
                    <label
                      className="block text-sm font-medium text-slate-700"
                      htmlFor="product_description"
                    >
                      Product description <span className="text-red-600">*</span>
                    </label>
                    <input
                      id="product_description"
                      ref={descriptionInputRef}
                      value={draft.product_description}
                      onChange={(e) =>
                        setDraft((d) =>
                          d ? { ...d, product_description: e.target.value } : d,
                        )
                      }
                      required
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                    <p className="mt-1 text-xs text-slate-500">
                      Must match the product/service name text on imported sale lines
                      (comparison is case-insensitive).
                    </p>
                  </div>

                  <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                    <div>
                      <label
                        className="block text-sm font-medium text-slate-700"
                        htmlFor="system_type"
                      >
                        System type
                      </label>
                      <select
                        id="system_type"
                        value={draft.system_type}
                        onChange={(e) =>
                          setDraft((d) =>
                            d ? { ...d, system_type: e.target.value } : d,
                          )
                        }
                        className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                      >
                        {SYSTEM_TYPE_OPTIONS.map((opt) => (
                          <option key={opt} value={opt}>
                            {opt}
                          </option>
                        ))}
                        {draft.system_type !== '' &&
                        !(SYSTEM_TYPE_OPTIONS as readonly string[]).includes(
                          draft.system_type,
                        ) ? (
                          <option value={draft.system_type}>
                            {draft.system_type} (legacy)
                          </option>
                        ) : null}
                        {draft.system_type === '' ? (
                          <option value="">(unset)</option>
                        ) : null}
                      </select>
                    </div>
                    <div>
                      <label
                        className="block text-sm font-medium text-slate-700"
                        htmlFor="product_type"
                      >
                        Product type
                      </label>
                      <select
                        id="product_type"
                        value={draft.product_type}
                        onChange={(e) =>
                          setDraft((d) =>
                            d ? { ...d, product_type: e.target.value } : d,
                          )
                        }
                        className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                      >
                        {PRODUCT_TYPE_OPTIONS.map((opt) => (
                          <option key={opt} value={opt}>
                            {opt}
                          </option>
                        ))}
                        {draft.product_type !== '' &&
                        !(PRODUCT_TYPE_OPTIONS as readonly string[]).includes(
                          draft.product_type,
                        ) ? (
                          <option value={draft.product_type}>
                            {draft.product_type} (legacy)
                          </option>
                        ) : null}
                      </select>
                    </div>
                  </div>

                  <div className="max-w-xs">
                    <label
                      className="block text-sm font-medium text-slate-700"
                      htmlFor="product_active"
                    >
                      Record status
                    </label>
                    <select
                      id="product_active"
                      value={draft.is_active ? 'active' : 'inactive'}
                      onChange={(e) =>
                        setDraft((d) =>
                          d ? { ...d, is_active: e.target.value === 'active' } : d,
                        )
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    >
                      <option value="active">Active</option>
                      <option value="inactive">Inactive</option>
                    </select>
                    <p className="mt-1 text-xs text-slate-500">
                      Inactive rows are kept for history but excluded from typical matching.
                    </p>
                  </div>

                  {isDraftSelected ? (
                    <div
                      className="rounded-lg border border-amber-200 bg-amber-50 px-3 py-2 text-xs text-amber-900"
                      data-testid="product-config-draft-notice"
                    >
                      <p className="font-medium text-amber-900">Unsaved draft</p>
                      <p className="mt-1">
                        This product has not been saved yet. Click Save changes to insert
                        it, or Delete product to discard it.
                      </p>
                    </div>
                  ) : (
                    <div className="rounded-lg border border-slate-100 bg-slate-50/80 px-3 py-2 text-xs text-slate-600">
                      <p className="font-medium text-slate-800">Read-only</p>
                      <p className="mt-1">
                        Updated:{' '}
                        {selected.updated_at
                          ? new Date(selected.updated_at).toLocaleString()
                          : '—'}
                      </p>
                    </div>
                  )}

                  <div className="flex flex-wrap items-center gap-3 border-t border-slate-100 pt-4">
                    <button
                      type="submit"
                      disabled={saveMut.isPending || !dirty}
                      className="rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
                      data-testid="product-config-save-btn"
                    >
                      {saveMut.isPending
                        ? isDraftSelected
                          ? 'Creating…'
                          : 'Saving…'
                        : isDraftSelected
                          ? 'Save changes'
                          : 'Save changes'}
                    </button>
                    <button
                      type="button"
                      onClick={handleDeleteClick}
                      disabled={deleteMut.isPending || saveMut.isPending}
                      className="rounded-md border border-red-300 bg-white px-4 py-2 text-sm font-medium text-red-700 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-50"
                      data-testid="product-config-delete-btn"
                    >
                      {deleteMut.isPending
                        ? 'Deleting…'
                        : isDraftSelected
                          ? 'Discard draft'
                          : 'Delete product'}
                    </button>
                    {saveMut.isError ? (
                      <span className="text-sm text-red-600">
                        {saveMut.error instanceof Error
                          ? saveMut.error.message
                          : String(saveMut.error)}
                      </span>
                    ) : null}
                    {deleteMut.isError ? (
                      <span className="text-sm text-red-600">
                        {deleteMut.error instanceof Error
                          ? deleteMut.error.message
                          : String(deleteMut.error)}
                      </span>
                    ) : null}
                  </div>
                </form>
              )}
            </section>
          </div>
        </div>
      </div>
    </div>
  )
}
