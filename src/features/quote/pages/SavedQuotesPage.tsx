import { useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'
import { useLocation, useNavigate } from 'react-router-dom'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useHasElevatedAccess } from '@/features/access/accessContext'
import { fetchSavedQuoteDetail } from '@/features/quote/data/savedQuoteDetailApi'
import { useDeleteSavedQuote } from '@/features/quote/hooks/useDeleteSavedQuote'
import { savedQuoteDetailQueryKey } from '@/features/quote/hooks/useSavedQuoteDetail'
import { useSavedQuotesSearch } from '@/features/quote/hooks/useSavedQuotesSearch'
import type { RequoteNavState } from '@/features/quote/lib/requoteFromSavedQuote'
import type {
  SavedQuoteSearchFilters,
  SavedQuoteSearchRow,
} from '@/features/quote/types/savedQuote'
import type { SavedQuoteDetail } from '@/features/quote/types/savedQuoteDetail'
import { formatDateTimeCompact, formatNzd } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'

const PAGE_SIZE = 50

const thBase =
  'border-b border-slate-200 px-2.5 py-1.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-3 sm:py-2 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700'
const tdBase = 'px-2.5 py-1.5 text-sm text-slate-700 sm:px-3 sm:py-2'

const inputClass =
  'w-full rounded-md border border-slate-300 bg-white px-2.5 py-1.5 text-sm text-slate-900 shadow-sm focus:border-violet-400 focus:outline-none focus:ring-1 focus:ring-violet-400'

/** Small inline debounce so the list doesn't refetch on every keystroke. */
function useDebouncedValue<T>(value: T, delayMs = 300): T {
  const [debounced, setDebounced] = useState(value)
  useEffect(() => {
    const t = setTimeout(() => setDebounced(value), delayMs)
    return () => clearTimeout(t)
  }, [value, delayMs])
  return debounced
}

export function SavedQuotesPage() {
  const elevated = useHasElevatedAccess()

  const [search, setSearch] = useState('')
  const [stylist, setStylist] = useState('')
  const [dateFrom, setDateFrom] = useState('')
  const [dateTo, setDateTo] = useState('')
  const [offset, setOffset] = useState(0)

  const debouncedSearch = useDebouncedValue(search, 300)
  const debouncedStylist = useDebouncedValue(stylist, 300)

  // Any filter change should reset pagination to page 1. Setters below
  // call `setOffset(0)` inline rather than chaining through an effect,
  // which keeps the render strictly one-pass.
  const onSearchChange = (v: string) => {
    setSearch(v)
    setOffset(0)
  }
  const onStylistChange = (v: string) => {
    setStylist(v)
    setOffset(0)
  }
  const onDateFromChange = (v: string) => {
    setDateFrom(v)
    setOffset(0)
  }
  const onDateToChange = (v: string) => {
    setDateTo(v)
    setOffset(0)
  }

  const filters: SavedQuoteSearchFilters = useMemo(
    () => ({
      search: debouncedSearch,
      // Stylist filter is only meaningful for elevated users; stylists
      // always see only their own quotes regardless of this value
      // (server enforces), but don't send it to keep the query key
      // cleaner.
      stylist: elevated ? debouncedStylist : null,
      dateFrom: dateFrom || null,
      dateTo: dateTo || null,
      limit: PAGE_SIZE,
      offset,
    }),
    [debouncedSearch, debouncedStylist, elevated, dateFrom, dateTo, offset],
  )

  const { data, isLoading, isError, error, isFetching, refetch } =
    useSavedQuotesSearch(filters)

  const rows = data ?? []
  const totalCount = rows.length > 0 ? rows[0]?.totalCount : 0
  const canPrev = offset > 0
  const canNext = offset + rows.length < (totalCount ?? 0)

  const hasFilters = Boolean(search || stylist || dateFrom || dateTo)

  function resetFilters() {
    setSearch('')
    setStylist('')
    setDateFrom('')
    setDateTo('')
    setOffset(0)
  }

  const deleteMutation = useDeleteSavedQuote()
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const navState = location.state as { deletedGuest?: string } | null
  const [lastDeletedGuest, setLastDeletedGuest] = useState<string | null>(
    navState?.deletedGuest ?? null,
  )

  // Per-row requote state.
  //   - `requotingId` is the id of the row whose detail is currently
  //     being fetched, so the row can render "Loading…" and every
  //     other action button can be held off.
  //   - `requoteError` shows a single inline banner if the detail
  //     fetch fails (e.g. the quote was deleted between list load and
  //     click). Cleared on the next attempt.
  const [requotingId, setRequotingId] = useState<string | null>(null)
  const [requoteError, setRequoteError] = useState<string | null>(null)

  const onDeleteRow = (row: SavedQuoteSearchRow) => {
    if (deleteMutation.isPending) return
    if (requotingId != null) return
    const label = row.guestName?.trim() || 'this quote'
    if (!window.confirm(`Delete quote for ${label}? This cannot be undone.`)) {
      return
    }
    setLastDeletedGuest(null)
    deleteMutation.mutate(row.id, {
      onSuccess: () => setLastDeletedGuest(label),
    })
  }

  /**
   * Reuses the existing Quote Detail → Guest Quote requote flow:
   * fetch the same detail payload (via React Query's shared cache, so
   * we reuse any prior fetch) and hand it to `/app/guest-quote` using the
   * same `RequoteNavState` shape as the detail page. The list page
   * itself is deliberately free of any mapping logic.
   */
  const onRequoteRow = async (row: SavedQuoteSearchRow) => {
    if (requotingId != null) return
    if (deleteMutation.isPending) return
    setRequoteError(null)
    setRequotingId(row.id)
    try {
      const detail: SavedQuoteDetail = await queryClient.fetchQuery({
        queryKey: savedQuoteDetailQueryKey(row.id),
        queryFn: () => fetchSavedQuoteDetail(row.id),
      })
      const state: RequoteNavState = {
        kind: 'requote-from-saved',
        sourceSavedQuoteId: row.id,
        detail,
      }
      navigate('/app/guest-quote', { state })
    } catch (err) {
      const { message, err: e } = queryErrorDetail(err)
      setRequoteError(
        e?.message ?? message ?? 'Unable to start requote from this quote.',
      )
      setRequotingId(null)
    }
  }

  const deleteError = deleteMutation.isError
    ? (queryErrorDetail(deleteMutation.error).err?.message ??
      queryErrorDetail(deleteMutation.error).message ??
      'Unable to delete quote.')
    : null

  return (
    <div data-testid="saved-quotes-page">
      <PageHeader
        title="Previous Quotes"
        description={
          elevated
            ? 'Find any quote saved through the Guest Quote page.'
            : 'Find quotes you have saved.'
        }
      />

      <div
        className="mb-4 rounded-lg border border-slate-200 bg-white px-3 py-3 shadow-sm"
        data-testid="saved-quotes-filters"
      >
        <div
          className={`grid grid-cols-1 gap-3 ${
            elevated ? 'sm:grid-cols-4' : 'sm:grid-cols-3'
          }`}
        >
          <label className="block text-xs font-medium text-slate-600">
            Search
            <input
              type="text"
              value={search}
              onChange={(e) => onSearchChange(e.target.value)}
              placeholder="Guest or stylist name"
              className={`mt-1 ${inputClass}`}
              data-testid="saved-quotes-filter-search"
            />
          </label>
          {elevated ? (
            <label className="block text-xs font-medium text-slate-600">
              Stylist
              <input
                type="text"
                value={stylist}
                onChange={(e) => onStylistChange(e.target.value)}
                placeholder="Stylist name"
                className={`mt-1 ${inputClass}`}
                data-testid="saved-quotes-filter-stylist"
              />
            </label>
          ) : null}
          <label className="block text-xs font-medium text-slate-600">
            Date from
            <input
              type="date"
              value={dateFrom}
              onChange={(e) => onDateFromChange(e.target.value)}
              className={`mt-1 ${inputClass}`}
              data-testid="saved-quotes-filter-date-from"
            />
          </label>
          <label className="block text-xs font-medium text-slate-600">
            Date to
            <input
              type="date"
              value={dateTo}
              onChange={(e) => onDateToChange(e.target.value)}
              className={`mt-1 ${inputClass}`}
              data-testid="saved-quotes-filter-date-to"
            />
          </label>
        </div>
        {hasFilters ? (
          <div className="mt-3 flex items-center justify-between">
            <button
              type="button"
              onClick={resetFilters}
              className="rounded-md border border-slate-200 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 shadow-sm hover:bg-slate-50"
              data-testid="saved-quotes-reset-filters"
            >
              Clear filters
            </button>
            {isFetching ? (
              <span className="text-xs text-slate-500">Refreshing…</span>
            ) : null}
          </div>
        ) : null}
      </div>

      {lastDeletedGuest && !deleteMutation.isPending ? (
        <div
          role="status"
          className="mb-3 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-xs text-emerald-800"
          data-testid="saved-quotes-delete-success"
        >
          Deleted quote for {lastDeletedGuest}.
        </div>
      ) : null}
      {deleteError ? (
        <div
          role="alert"
          className="mb-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-800"
          data-testid="saved-quotes-delete-error"
        >
          {deleteError}
        </div>
      ) : null}
      {requoteError ? (
        <div
          role="alert"
          className="mb-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-800"
          data-testid="saved-quotes-requote-error"
        >
          {requoteError}
        </div>
      ) : null}

      {isLoading ? (
        <LoadingState
          message="Loading quotes…"
          testId="saved-quotes-loading"
        />
      ) : isError ? (
        <ErrorState
          title="Could not load quotes"
          error={queryErrorDetail(error).err}
          message={queryErrorDetail(error).message}
          onRetry={() => void refetch()}
          testId="saved-quotes-error"
        />
      ) : rows.length === 0 ? (
        <EmptyState
          title={hasFilters ? 'No quotes match those filters.' : 'No saved quotes yet.'}
          description={
            hasFilters
              ? 'Try widening the search or clearing filters.'
              : 'Quotes saved from the Guest Quote page will appear here.'
          }
          testId="saved-quotes-empty"
        />
      ) : (
        <SavedQuotesTable
          rows={rows}
          elevated={elevated}
          onDelete={onDeleteRow}
          deletingId={deleteMutation.isPending ? deleteMutation.variables : null}
          onRequote={onRequoteRow}
          requotingId={requotingId}
        />
      )}

      {rows.length > 0 ? (
        <div
          className="mt-3 flex items-center justify-between text-xs text-slate-600"
          data-testid="saved-quotes-pagination"
        >
          <span>
            Showing <span className="font-medium">{offset + 1}</span>–
            <span className="font-medium">{offset + rows.length}</span> of{' '}
            <span className="font-medium">{totalCount}</span>
          </span>
          <div className="flex gap-2">
            <button
              type="button"
              onClick={() => setOffset((o) => Math.max(0, o - PAGE_SIZE))}
              disabled={!canPrev}
              className="rounded-md border border-slate-200 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 shadow-sm hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
              data-testid="saved-quotes-prev"
            >
              Previous
            </button>
            <button
              type="button"
              onClick={() => setOffset((o) => o + PAGE_SIZE)}
              disabled={!canNext}
              className="rounded-md border border-slate-200 bg-white px-3 py-1.5 text-xs font-medium text-slate-700 shadow-sm hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
              data-testid="saved-quotes-next"
            >
              Next
            </button>
          </div>
        </div>
      ) : null}
    </div>
  )
}

function SavedQuotesTable({
  rows,
  elevated,
  onDelete,
  deletingId,
  onRequote,
  requotingId,
}: {
  rows: SavedQuoteSearchRow[]
  elevated: boolean
  onDelete: (row: SavedQuoteSearchRow) => void
  deletingId: string | null | undefined
  onRequote: (row: SavedQuoteSearchRow) => void
  requotingId: string | null
}) {
  const navigate = useNavigate()
  const open = (id: string) => navigate(`/app/previous-quotes/${id}`)
  // Hold off both row actions while the other is in flight so the two
  // mutations (delete) / async navigations (requote) can't race.
  const anyActionPending = deletingId != null || requotingId != null
  return (
    <div data-testid="saved-quotes-table">
      {/* Mobile: stacked card list (< md). Keeps the primary fields
          (date, guest, total) on one line, with notes/lines/stylist
          underneath, and puts Requote/Delete on their own row so the
          touch targets don't get squeezed. Desktop table below is
          hidden on the same breakpoint. */}
      <ul
        className="divide-y divide-slate-200 overflow-hidden rounded-lg border border-slate-200 bg-white shadow-sm md:hidden"
        data-testid="saved-quotes-card-list"
      >
        {rows.map((row) => (
          <li key={row.id}>
            <button
              type="button"
              onClick={(e) => {
                const target = e.target as HTMLElement
                if (target.closest('[data-row-action]')) return
                open(row.id)
              }}
              className="w-full px-3 py-3 text-left transition hover:bg-slate-50 focus:outline-none focus-visible:bg-slate-50 focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1"
              aria-label={`Open quote for ${row.guestName?.trim() || 'guest without name'}`}
              data-testid={`saved-quotes-card-${row.id}`}
            >
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-semibold text-slate-900">
                    {row.guestName?.trim() || (
                      <span className="italic text-slate-400">No name</span>
                    )}
                  </p>
                  <p className="mt-0.5 text-xs text-slate-500">
                    {formatDateTimeCompact(row.createdAt)}
                  </p>
                </div>
                <p className="shrink-0 text-sm font-semibold tabular-nums text-slate-900">
                  {formatNzd(row.grandTotal)}
                </p>
              </div>
              <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-0.5 text-xs text-slate-600">
                <span className="tabular-nums">
                  {row.lineCount} line{row.lineCount === 1 ? '' : 's'}
                </span>
                {elevated ? (
                  <span className="truncate">
                    Stylist: {row.stylistDisplayName}
                  </span>
                ) : null}
              </div>
              {row.notesPreview ? (
                <p className="mt-1 line-clamp-2 break-words text-xs text-slate-600">
                  {row.notesPreview}
                </p>
              ) : null}
              <div
                className="mt-2 flex items-center gap-2"
                data-row-action
              >
                <button
                  type="button"
                  data-row-action
                  onClick={(e) => {
                    e.stopPropagation()
                    void onRequote(row)
                  }}
                  disabled={anyActionPending}
                  aria-busy={requotingId === row.id}
                  className="inline-flex items-center rounded-md border border-violet-200 bg-white px-2.5 py-1 text-xs font-medium text-violet-700 shadow-sm hover:bg-violet-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1 disabled:cursor-wait disabled:opacity-50"
                  data-testid={`saved-quotes-card-requote-${row.id}`}
                >
                  {requotingId === row.id ? 'Loading…' : 'Requote'}
                </button>
                <button
                  type="button"
                  data-row-action
                  onClick={(e) => {
                    e.stopPropagation()
                    onDelete(row)
                  }}
                  disabled={anyActionPending}
                  aria-busy={deletingId === row.id}
                  className="inline-flex items-center rounded-md border border-rose-200 bg-white px-2.5 py-1 text-xs font-medium text-rose-700 shadow-sm hover:bg-rose-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-rose-500 focus-visible:ring-offset-1 disabled:cursor-wait disabled:opacity-50"
                  data-testid={`saved-quotes-card-delete-${row.id}`}
                >
                  {deletingId === row.id ? 'Deleting…' : 'Delete'}
                </button>
              </div>
            </button>
          </li>
        ))}
      </ul>

      {/* Desktop: wide table retained as-is. Horizontal scroll is kept
          as a last-resort for awkward widths between tablet and
          desktop where 6 columns briefly don't fit. */}
      <div className="hidden overflow-x-auto rounded-lg border border-slate-200 bg-white shadow-sm md:block">
      <table className="min-w-full divide-y divide-slate-200">
        <thead className="bg-slate-50">
          <tr>
            <th className={`${thBase} w-32`}>Date</th>
            <th className={thBase}>Guest</th>
            {elevated ? <th className={thBase}>Stylist</th> : null}
            <th className={`${thBase} w-20 text-right`}>Lines</th>
            <th className={`${thBase} w-28 text-right`}>Total</th>
            <th className={thBase}>Notes</th>
            <th className={`${thBase} w-40 text-right`}>
              <span className="sr-only">Actions</span>
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((row) => (
            <tr
              key={row.id}
              className="cursor-pointer transition hover:bg-slate-50 focus-within:bg-slate-50"
              onClick={(e) => {
                // Row navigation stops at any element that opts out — the
                // Delete button uses this hook so it can confirm without
                // also opening the detail page.
                const target = e.target as HTMLElement
                if (target.closest('[data-row-action]')) return
                open(row.id)
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  const target = e.target as HTMLElement
                  if (target.closest('[data-row-action]')) return
                  e.preventDefault()
                  open(row.id)
                }
              }}
              tabIndex={0}
              role="button"
              aria-label={`Open quote for ${row.guestName?.trim() || 'guest without name'}`}
              data-testid={`saved-quotes-row-${row.id}`}
            >
              <td className={`${tdBase} whitespace-nowrap`}>
                <span className="font-medium text-slate-900">
                  {formatDateTimeCompact(row.createdAt)}
                </span>
              </td>
              <td className={tdBase}>
                <span className="text-slate-900">
                  {row.guestName?.trim() || (
                    <span className="italic text-slate-400">No name</span>
                  )}
                </span>
              </td>
              {elevated ? (
                <td className={`${tdBase} whitespace-nowrap`}>
                  {row.stylistDisplayName}
                </td>
              ) : null}
              <td className={`${tdBase} whitespace-nowrap text-right tabular-nums`}>
                {row.lineCount}
              </td>
              <td className={`${tdBase} whitespace-nowrap text-right tabular-nums font-medium text-slate-900`}>
                {formatNzd(row.grandTotal)}
              </td>
              <td className={`${tdBase} max-w-[28rem] text-slate-600`}>
                {row.notesPreview ? (
                  <span className="line-clamp-2 break-words">
                    {row.notesPreview}
                  </span>
                ) : (
                  <span className="text-slate-400">—</span>
                )}
              </td>
              <td className={`${tdBase} whitespace-nowrap text-right`}>
                <div
                  className="inline-flex items-center gap-2"
                  data-row-action
                  // `data-row-action` on the wrapper is belt-and-braces:
                  // every child button stops propagation individually,
                  // but this also guards against future additions (e.g.
                  // dropdown menu) opening the row by accident.
                >
                  <button
                    type="button"
                    data-row-action
                    onClick={(e) => {
                      e.stopPropagation()
                      void onRequote(row)
                    }}
                    // Requote does an async detail fetch then navigates
                    // away — disable while that specific row is loading,
                    // and also while a delete anywhere on the page is
                    // running so the two actions can't race.
                    disabled={anyActionPending}
                    aria-busy={requotingId === row.id}
                    className="inline-flex items-center rounded-md border border-violet-200 bg-white px-2 py-1 text-xs font-medium text-violet-700 shadow-sm hover:bg-violet-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1 disabled:cursor-wait disabled:opacity-50"
                    data-testid={`saved-quotes-row-requote-${row.id}`}
                  >
                    {requotingId === row.id ? 'Loading…' : 'Requote'}
                  </button>
                  <button
                    type="button"
                    data-row-action
                    onClick={(e) => {
                      e.stopPropagation()
                      onDelete(row)
                    }}
                    // Disable every row's delete while ANY action is in
                    // flight — the clicked row shows "Deleting…" for
                    // feedback, and the others simply cannot be clicked
                    // until the current mutation settles. Prevents a
                    // second mutate() call overwriting the first one's
                    // variables/callbacks.
                    disabled={anyActionPending}
                    aria-busy={deletingId === row.id}
                    className="inline-flex items-center rounded-md border border-rose-200 bg-white px-2 py-1 text-xs font-medium text-rose-700 shadow-sm hover:bg-rose-50 focus:outline-none focus-visible:ring-2 focus-visible:ring-rose-500 focus-visible:ring-offset-1 disabled:cursor-wait disabled:opacity-50"
                    data-testid={`saved-quotes-row-delete-${row.id}`}
                  >
                    {deletingId === row.id ? 'Deleting…' : 'Delete'}
                  </button>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      </div>
    </div>
  )
}
