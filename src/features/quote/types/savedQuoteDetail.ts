/**
 * Types for the Quote Detail page.
 *
 * Matches the JSONB payload returned by `public.get_saved_quote_detail`
 * (see supabase/migrations/20260501220000_get_saved_quote_detail_rpc.sql).
 * All `*_snapshot` fields in the DB are exposed here without the
 * `_snapshot` suffix — the shape the stylist saw at save time is the
 * whole point of this view, so the qualifier would be redundant on the
 * client.
 */

export type SavedQuoteDetailHeader = {
  id: string
  /** ISO timestamp at which the quote was saved. */
  createdAt: string
  /** Date the stylist assigned to the quote (YYYY-MM-DD). */
  quoteDate: string
  guestName: string | null
  stylistDisplayName: string
  notes: string | null
  grandTotal: number
  greenFeeApplied: number
}

export type SavedQuoteDetailSectionTotal = {
  displayOrder: number
  sectionName: string | null
  summaryLabel: string
  sectionTotal: number
}

export type SavedQuoteDetailSelectedOption = {
  label: string
  valueKey: string
  price: number | null
}

export type SavedQuoteDetailLine = {
  id: string
  lineOrder: number
  sectionId: string | null
  sectionName: string
  sectionSummaryLabel: string
  serviceName: string
  summaryGroup: string
  inputType: string
  pricingType: string
  selectedRole: string | null
  numericQuantity: number | null
  numericUnitLabel: string | null
  extraUnitsSelected: number | null
  /** Raw JSON value of `special_extra_rows_snapshot`, may be null/array. */
  specialExtraRows: unknown
  unitPrice: number | null
  lineTotal: number
  includeInSummary: boolean
  selectedOptions: SavedQuoteDetailSelectedOption[]
}

export type SavedQuoteDetail = {
  header: SavedQuoteDetailHeader
  sectionTotals: SavedQuoteDetailSectionTotal[]
  lines: SavedQuoteDetailLine[]
}
