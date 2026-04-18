/**
 * Shared types for the Previous Quotes page.
 *
 * Matches the row shape returned by `public.get_saved_quotes_search`
 * (see supabase/migrations/20260501210000_get_saved_quotes_search_rpc.sql).
 */

export type SavedQuoteSearchRow = {
  id: string
  /** ISO timestamp for when the quote was saved. */
  createdAt: string
  /** Date the stylist assigned to the quote (YYYY-MM-DD). */
  quoteDate: string
  guestName: string | null
  stylistUserId: string
  stylistDisplayName: string
  /** First ~120 chars of the notes field, or null when empty. */
  notesPreview: string | null
  grandTotal: number
  lineCount: number
  /**
   * Count of matching rows before LIMIT/OFFSET. Same value on every row;
   * used to drive pagination without a second round trip.
   */
  totalCount: number
}

export type SavedQuoteSearchFilters = {
  search?: string | null
  stylist?: string | null
  guestName?: string | null
  /** Inclusive lower bound on quote_date, YYYY-MM-DD. */
  dateFrom?: string | null
  /** Inclusive upper bound on quote_date, YYYY-MM-DD. */
  dateTo?: string | null
  limit?: number
  offset?: number
}
