/**
 * Data layer for persisting a Guest Quote via the
 * `public.save_guest_quote(payload jsonb)` RPC.
 *
 * Two concerns live here:
 *   1. `buildSaveGuestQuotePayload` — pure mapper from the page's local
 *      `GuestQuoteDraft` into the RPC's JSONB shape. Documented inline.
 *   2. `saveGuestQuote` — thin Supabase caller that posts the payload and
 *      returns the new `saved_quotes.id`.
 *
 * The server recomputes every price from live config, so this client
 * mapper only needs to faithfully forward the stylist's selections — not
 * totals.
 */
import type { PostgrestError } from '@supabase/supabase-js'

import type {
  GuestQuoteDraft,
  GuestQuoteLineDraft,
} from '@/features/quote/state/guestQuoteDraft'
import type {
  StylistQuoteConfig,
  StylistQuoteService,
} from '@/features/quote/types/stylistQuoteConfig'
import { priceForLine } from '@/features/quote/lib/quoteCalculations'
import { requireSupabaseClient } from '@/lib/supabase'

/**
 * JSONB payload accepted by `public.save_guest_quote(payload jsonb)`.
 * Field names / types mirror the RPC header comment in
 * `supabase/migrations/20260501180000_save_guest_quote_rpc.sql`.
 */
export type SaveGuestQuoteLinePayload = {
  service_id: string
  selected_role: string | null
  selected_option_ids: string[] | null
  numeric_quantity: number | null
  extra_units_selected: number | null
  special_extra_rows: Array<{ units: number; grams: number }> | null
}

export type SaveGuestQuotePayload = {
  guest_name: string | null
  notes: string | null
  /** Omitted — server defaults to current_date. */
  quote_date: null
  /**
   * Server prefers the stylist linked via `staff_member_user_access`, then
   * falls back to this string. Safe to pass even when a staff link exists.
   */
  stylist_display_name: string | null
  lines: SaveGuestQuoteLinePayload[]
}

/**
 * Client-side validation error thrown by `buildSaveGuestQuotePayload`
 * before hitting Supabase. These map cleanly to user-facing messages in
 * the page, separately from server-side rejections.
 */
export class SaveGuestQuoteValidationError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'SaveGuestQuoteValidationError'
  }
}

function trimOrNull(v: string): string | null {
  const t = v.trim()
  return t === '' ? null : t
}

/**
 * Map one in-progress line into the shape expected by the RPC. Only the
 * fields relevant to the service's `pricingType` / `inputType` are
 * populated — every other field is emitted as `null` so the server does
 * not consider unrelated data.
 *
 * Returns `null` when the line cannot be persisted (missing required
 * field for its pricing type); the caller skips those silently — the UI
 * is expected to guide users to valid input and we don't want a half-
 * filled row to block an otherwise-valid save.
 */
function mapLineToPayload(
  service: StylistQuoteService,
  line: GuestQuoteLineDraft,
): SaveGuestQuoteLinePayload | null {
  const base: SaveGuestQuoteLinePayload = {
    service_id: service.id,
    selected_role: null,
    selected_option_ids: null,
    numeric_quantity: null,
    extra_units_selected: null,
    special_extra_rows: null,
  }

  switch (service.pricingType) {
    case 'fixed_price':
      // Nothing to send beyond `service_id`. Server reads `fixed_price`
      // from live config.
      return base

    case 'role_price':
      if (!line.selectedRole) return null
      return { ...base, selected_role: line.selectedRole }

    case 'option_price':
      if (line.selectedOptionIds.length !== 1) return null
      return { ...base, selected_option_ids: [...line.selectedOptionIds] }

    case 'numeric_multiplier': {
      if (line.numericQuantity == null || line.numericQuantity <= 0) return null
      return { ...base, numeric_quantity: line.numericQuantity }
    }

    case 'extra_unit_price': {
      if (line.extraUnitsSelected == null || line.extraUnitsSelected < 0)
        return null
      return { ...base, extra_units_selected: line.extraUnitsSelected }
    }

    case 'special_extra_product': {
      const cfg = service.specialExtra
      const grams = line.specialExtraGrams
      if (!cfg || grams == null || grams <= 0) return null
      const gramsPerUnit = cfg.gramsPerUnit > 0 ? cfg.gramsPerUnit : 1
      const units = Math.ceil(grams / gramsPerUnit)
      // The UI exposes a single grams input per service; always send
      // exactly one row. The `save_guest_quote` RPC still validates
      // row count / per-row units against the deprecated
      // `numberOfRows` / `maxUnitsPerRow` config fields — new services
      // default them to `1` / `999` so validation never rejects
      // realistic input, and existing rows keep their original values.
      return {
        ...base,
        special_extra_rows: [{ units, grams }],
      }
    }

    default:
      return null
  }
}

/**
 * Additional selections that matter for the saved-quote snapshot but
 * aren't priced directly — specifically `option_radio` / `dropdown`
 * services whose pricing_type is not `option_price`. The RPC snapshots
 * `saved_quote_line_options` for these based on `selected_option_ids`.
 */
function attachDisplayOnlyOptions(
  service: StylistQuoteService,
  line: GuestQuoteLineDraft,
  payload: SaveGuestQuoteLinePayload,
): SaveGuestQuoteLinePayload {
  if (payload.selected_option_ids != null) return payload
  if (
    (service.inputType === 'option_radio' || service.inputType === 'dropdown') &&
    line.selectedOptionIds.length > 0
  ) {
    return { ...payload, selected_option_ids: [...line.selectedOptionIds] }
  }
  return payload
}

/**
 * Build the JSONB payload for `public.save_guest_quote`. Throws
 * `SaveGuestQuoteValidationError` for the minimal set of client-side
 * checks we want to surface before hitting Supabase:
 *   - guest name required by settings
 *   - at least one saveable line
 *
 * Anything beyond that is intentionally left to the server, which is
 * the authoritative validator.
 */
export function buildSaveGuestQuotePayload(
  config: StylistQuoteConfig,
  draft: GuestQuoteDraft,
  opts: { stylistDisplayName: string | null },
): SaveGuestQuotePayload {
  const guestName = trimOrNull(draft.guestName)
  if (config.settings.guestNameRequired && guestName == null) {
    throw new SaveGuestQuoteValidationError(
      'Guest name is required for this quote.',
    )
  }

  const lines: SaveGuestQuoteLinePayload[] = []
  for (const section of config.sections) {
    for (const service of section.services) {
      const line = draft.lines[service.id]
      if (!line || !line.selected) continue
      // Skip lines that would otherwise contribute nothing; keeps the
      // payload lean and avoids server-side rejections for "empty"
      // rows when a user toggled then emptied a numeric field.
      const pricing = priceForLine(service, line)
      if (pricing.lineTotal <= 0 && service.pricingType !== 'fixed_price')
        continue

      let payload = mapLineToPayload(service, line)
      if (!payload) continue
      payload = attachDisplayOnlyOptions(service, line, payload)
      lines.push(payload)
    }
  }

  if (lines.length === 0) {
    throw new SaveGuestQuoteValidationError(
      'Select at least one service before submitting.',
    )
  }

  return {
    guest_name: guestName,
    notes: config.settings.notesEnabled ? trimOrNull(draft.notes) : null,
    quote_date: null,
    stylist_display_name: trimOrNull(opts.stylistDisplayName ?? ''),
    lines,
  }
}

function toError(op: string, err: PostgrestError | Error): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

/**
 * Call `public.save_guest_quote(payload)` and return the new
 * `saved_quotes.id`. The server is the source of truth for all
 * pricing — this function does not recompute anything.
 */
export async function saveGuestQuote(
  payload: SaveGuestQuotePayload,
): Promise<string> {
  const { data, error } = await requireSupabaseClient().rpc('save_guest_quote', {
    payload: payload as unknown as Record<string, unknown>,
  })
  if (error) throw toError('save_guest_quote', error)
  if (typeof data !== 'string' || data.length === 0) {
    throw new Error('save_guest_quote: unexpected empty response')
  }
  return data
}
