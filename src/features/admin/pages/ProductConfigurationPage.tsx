import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useProductConfiguration } from '@/features/admin/hooks/useProductConfiguration'
import type { ProductMasterRow } from '@/features/admin/types/productConfiguration'
import {
  insertProductMaster,
  updateProductMaster,
  type ProductMasterUpdatePayload,
} from '@/lib/productMasterApi'
import { queryErrorDetail } from '@/lib/queryError'

type StatusFilter = 'all' | 'active' | 'inactive'

type ProductFormDraft = {
  id: string
  product_description: string
  system_type: string
  product_type: string
  is_active: boolean
}

function draftFromRow(row: ProductMasterRow): ProductFormDraft {
  return {
    id: row.id,
    product_description: row.product_description,
    system_type: row.system_type ?? '',
    product_type: row.product_type ?? '',
    is_active: row.is_active,
  }
}

function ProductListRow({
  row,
  active,
  onSelect,
}: {
  row: ProductMasterRow
  active: boolean
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
            row.is_active ? 'text-emerald-700' : 'text-slate-400'
          }`}
        >
          {row.is_active ? 'Active' : 'Inactive'}
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

  const products = data?.products ?? []

  const systemTypeOptions = useMemo(() => {
    const set = new Set<string>()
    for (const p of products) {
      const s = (p.system_type ?? '').trim()
      if (s) set.add(s)
    }
    return [...set].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }))
  }, [products])

  const productTypeOptions = useMemo(() => {
    const set = new Set<string>()
    for (const p of products) {
      const s = (p.product_type ?? '').trim()
      if (s) set.add(s)
    }
    return [...set].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }))
  }, [products])

  const filteredProducts = useMemo(() => {
    const q = search.trim().toLowerCase()
    return products.filter((p) => {
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
  }, [products, search, statusFilter, systemTypeFilter, productTypeFilter])

  const selected = useMemo(
    () => products.find((p) => p.id === selectedId) ?? null,
    [products, selectedId],
  )

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

  const dirty = useMemo(() => {
    if (!selected || !draft) return false
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

  const saveMut = useMutation({
    mutationFn: async () => {
      if (!draft) return
      const payload: ProductMasterUpdatePayload = {
        id: draft.id,
        product_description: draft.product_description,
        system_type: draft.system_type || null,
        product_type: draft.product_type || null,
        is_active: draft.is_active,
      }
      await updateProductMaster(payload)
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['product-configuration'] })
    },
  })

  const createMut = useMutation({
    mutationFn: () =>
      insertProductMaster({
        product_description: `New product ${new Date().toISOString().slice(0, 16).replace('T', ' ')}`,
      }),
    onSuccess: (row) => {
      void queryClient.invalidateQueries({ queryKey: ['product-configuration'] })
      setSelectedId(row.id)
    },
  })

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
              onClick={() => void createMut.mutateAsync()}
              disabled={createMut.isPending}
              className="w-full shrink-0 rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:opacity-50"
            >
              {createMut.isPending ? 'Creating…' : 'Create new product'}
            </button>
            {createMut.isError ? (
              <p className="mt-2 shrink-0 text-xs text-red-600">
                {createMut.error instanceof Error
                  ? createMut.error.message
                  : String(createMut.error)}
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
                      onSelect={setSelectedId}
                    />
                  ))}
                </ul>
              )}
            </div>
          </aside>

          <div className="min-h-0 min-w-0 flex-1 overflow-y-auto pb-6 pt-0">
            <PageHeader
              title="Product Configuration"
              description="Manage the product records used to classify imported sales lines into retail, professional product, service, and special-case categories. These classifications flow into remuneration rates and downstream reporting — changes can affect commission calculations."
            />

            <div
              className="mb-6 w-full rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950"
              role="status"
            >
              <span className="font-medium">Important: </span>
              Imported Sales Daily Sheets match lines to products by description. Editing
              descriptions or deactivating products can change how future imports classify
              lines and how commission rates apply.
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
                      <input
                        id="system_type"
                        value={draft.system_type}
                        onChange={(e) =>
                          setDraft((d) =>
                            d ? { ...d, system_type: e.target.value } : d,
                          )
                        }
                        className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                      />
                    </div>
                    <div>
                      <label
                        className="block text-sm font-medium text-slate-700"
                        htmlFor="product_type"
                      >
                        Product type
                      </label>
                      <input
                        id="product_type"
                        value={draft.product_type}
                        onChange={(e) =>
                          setDraft((d) =>
                            d ? { ...d, product_type: e.target.value } : d,
                          )
                        }
                        className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                      />
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

                  <div className="rounded-lg border border-slate-100 bg-slate-50/80 px-3 py-2 text-xs text-slate-600">
                    <p className="font-medium text-slate-800">Read-only</p>
                    <p className="mt-1">
                      Updated:{' '}
                      {selected.updated_at
                        ? new Date(selected.updated_at).toLocaleString()
                        : '—'}
                    </p>
                  </div>

                  <div className="flex flex-wrap items-center gap-3 border-t border-slate-100 pt-4">
                    <button
                      type="submit"
                      disabled={saveMut.isPending || !dirty}
                      className="rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      {saveMut.isPending ? 'Saving…' : 'Save changes'}
                    </button>
                    {saveMut.isError ? (
                      <span className="text-sm text-red-600">
                        {saveMut.error instanceof Error
                          ? saveMut.error.message
                          : String(saveMut.error)}
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
