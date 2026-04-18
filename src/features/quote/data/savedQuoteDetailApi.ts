/**
 * Data layer for the saved Quote Detail page.
 *
 * Calls the SECURITY DEFINER RPC `public.get_saved_quote_detail(p_id)`
 * which enforces stylist-vs-elevated access server-side. The RPC raises
 * a generic "quote not found" error for both missing-by-id and
 * belongs-to-another-stylist cases, so callers see a single shape of
 * failure — we never leak existence of inaccessible quotes.
 */
import type { PostgrestError } from '@supabase/supabase-js'

import type {
  SavedQuoteDetail,
  SavedQuoteDetailHeader,
  SavedQuoteDetailLine,
  SavedQuoteDetailSectionTotal,
  SavedQuoteDetailSelectedOption,
} from '@/features/quote/types/savedQuoteDetail'
import { requireSupabaseClient } from '@/lib/supabase'

type Row = Record<string, unknown>

function toError(op: string, err: PostgrestError | Error): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

function asObject(v: unknown): Row | null {
  return v != null && typeof v === 'object' && !Array.isArray(v)
    ? (v as Row)
    : null
}

function asArray(v: unknown): unknown[] {
  return Array.isArray(v) ? v : []
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

function asNumberOrNull(v: unknown): number | null {
  if (v == null) return null
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

function asBool(v: unknown, fallback: boolean): boolean {
  return typeof v === 'boolean' ? v : fallback
}

function mapHeader(row: Row): SavedQuoteDetailHeader {
  return {
    id: asString(row.id),
    createdAt: asString(row.created_at),
    quoteDate: asString(row.quote_date),
    guestName: asStringOrNull(row.guest_name),
    stylistDisplayName: asString(row.stylist_display_name),
    notes: asStringOrNull(row.notes),
    grandTotal: asNumber(row.grand_total),
    greenFeeApplied: asNumber(row.green_fee_applied),
  }
}

function mapSectionTotal(row: Row): SavedQuoteDetailSectionTotal {
  return {
    displayOrder: asNumber(row.display_order),
    sectionName: asStringOrNull(row.section_name),
    summaryLabel: asString(row.summary_label),
    sectionTotal: asNumber(row.section_total),
  }
}

function mapSelectedOption(row: Row): SavedQuoteDetailSelectedOption {
  return {
    label: asString(row.label),
    valueKey: asString(row.value_key),
    price: asNumberOrNull(row.price),
  }
}

function mapLine(row: Row): SavedQuoteDetailLine {
  return {
    id: asString(row.id),
    lineOrder: asNumber(row.line_order),
    sectionId: asStringOrNull(row.section_id),
    sectionName: asString(row.section_name),
    sectionSummaryLabel: asString(row.section_summary_label),
    serviceName: asString(row.service_name),
    summaryGroup: asString(row.summary_group),
    inputType: asString(row.input_type),
    pricingType: asString(row.pricing_type),
    selectedRole: asStringOrNull(row.selected_role),
    numericQuantity: asNumberOrNull(row.numeric_quantity),
    numericUnitLabel: asStringOrNull(row.numeric_unit_label),
    extraUnitsSelected: asNumberOrNull(row.extra_units_selected),
    specialExtraRows: row.special_extra_rows ?? null,
    unitPrice: asNumberOrNull(row.unit_price),
    lineTotal: asNumber(row.line_total),
    includeInSummary: asBool(row.include_in_summary, true),
    selectedOptions: asArray(row.selected_options)
      .map((o) => mapSelectedOption(asObject(o) ?? {})),
  }
}

function mapPayload(payload: unknown): SavedQuoteDetail {
  const root = asObject(payload) ?? {}
  return {
    header: mapHeader(asObject(root.header) ?? {}),
    sectionTotals: asArray(root.section_totals)
      .map((t) => mapSectionTotal(asObject(t) ?? {}))
      .sort((a, b) => a.displayOrder - b.displayOrder),
    lines: asArray(root.lines)
      .map((l) => mapLine(asObject(l) ?? {}))
      .sort((a, b) => a.lineOrder - b.lineOrder),
  }
}

/**
 * Load a single saved quote's full contents. Throws a generic error for
 * both "does not exist" and "belongs to another stylist" — the UI should
 * render the same not-found state for both.
 */
export async function fetchSavedQuoteDetail(
  quoteId: string,
): Promise<SavedQuoteDetail> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_saved_quote_detail',
    { p_saved_quote_id: quoteId },
  )
  if (error) throw toError('get_saved_quote_detail', error)
  return mapPayload(data)
}
