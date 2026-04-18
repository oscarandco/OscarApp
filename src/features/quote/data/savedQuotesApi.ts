/**
 * Data layer for the Previous Quotes page.
 *
 * Reads route through the SECURITY DEFINER RPC
 * `public.get_saved_quotes_search(...)`, which enforces the stylist-vs-
 * elevated access rule server-side and returns a single flat row set
 * shaped for the list UI.
 */
import type { PostgrestError } from '@supabase/supabase-js'

import type {
  SavedQuoteSearchFilters,
  SavedQuoteSearchRow,
} from '@/features/quote/types/savedQuote'
import { requireSupabaseClient } from '@/lib/supabase'

type Row = Record<string, unknown>

function toError(op: string, err: PostgrestError | Error): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

function asString(v: unknown): string {
  return typeof v === 'string' ? v : v == null ? '' : String(v)
}

function asStringOrNull(v: unknown): string | null {
  if (v == null) return null
  const s = typeof v === 'string' ? v : String(v)
  return s.length === 0 ? null : s
}

function asNumber(v: unknown): number {
  if (v == null) return 0
  if (typeof v === 'number') return v
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

function mapRow(row: Row): SavedQuoteSearchRow {
  return {
    id: asString(row.id),
    createdAt: asString(row.created_at),
    quoteDate: asString(row.quote_date),
    guestName: asStringOrNull(row.guest_name),
    stylistUserId: asString(row.stylist_user_id),
    stylistDisplayName: asString(row.stylist_display_name),
    notesPreview: asStringOrNull(row.notes_preview),
    grandTotal: asNumber(row.grand_total),
    lineCount: asNumber(row.line_count),
    totalCount: asNumber(row.total_count),
  }
}

/**
 * Normalise a filter string: trim, empty → null, cap length at a sane
 * upper bound so we don't build a many-kilobyte ILIKE pattern by
 * accident.
 */
function normaliseText(s: string | null | undefined): string | null {
  if (s == null) return null
  const t = s.trim()
  if (t === '') return null
  return t.slice(0, 200)
}

function normaliseDate(d: string | null | undefined): string | null {
  if (d == null) return null
  const t = d.trim()
  if (t === '') return null
  // Expect YYYY-MM-DD; leave further validation to the server.
  return t
}

/**
 * Call `public.get_saved_quotes_search` and return the mapped list.
 * Server decides visibility (stylists only see their own; elevated sees
 * all) — the frontend does not re-filter on stylist ownership.
 */
export async function searchSavedQuotes(
  filters: SavedQuoteSearchFilters,
): Promise<SavedQuoteSearchRow[]> {
  const params = {
    p_search: normaliseText(filters.search),
    p_stylist: normaliseText(filters.stylist),
    p_guest_name: normaliseText(filters.guestName),
    p_date_from: normaliseDate(filters.dateFrom),
    p_date_to: normaliseDate(filters.dateTo),
    p_limit: filters.limit ?? 100,
    p_offset: filters.offset ?? 0,
  }
  const { data, error } = await requireSupabaseClient().rpc(
    'get_saved_quotes_search',
    params,
  )
  if (error) throw toError('get_saved_quotes_search', error)
  if (!Array.isArray(data)) return []
  return data.map((r) => mapRow((r ?? {}) as Row))
}
