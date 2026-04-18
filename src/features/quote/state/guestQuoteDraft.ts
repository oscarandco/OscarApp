/**
 * Local draft state for the stylist-facing Guest Quote page.
 *
 * Intentionally a flat, serializable shape so it can later be mapped into
 * the `save_guest_quote(payload jsonb)` RPC without losing information or
 * needing a dedicated converter layer. Nothing here persists to Supabase
 * yet — this module is pure data + pure helpers.
 *
 * Keyed by service.id for O(1) reads in the page/summary, and so that
 * config reloads that preserve service ids also preserve any local edits.
 */

import type { QuoteRole } from '@/features/admin/types/quoteConfiguration'
import type { StylistQuoteConfig } from '@/features/quote/types/stylistQuoteConfig'

/**
 * Per-service draft state. All fields are populated to keep the shape
 * deterministic, but only the fields relevant to the service's input /
 * pricing type are consulted by the calculator and by save mapping.
 */
export type GuestQuoteLineDraft = {
  /**
   * Did the stylist opt this service into the quote at all?
   *
   *   - checkbox / option_radio / dropdown / role_radio: reflects the user's
   *     direct selection.
   *   - numeric_input / extra_units / special_extra_product: derived — true
   *     whenever the entered quantity is > 0.
   */
  selected: boolean

  /** role_radio only. */
  selectedRole: QuoteRole | null

  /** option_radio / dropdown only. Array-shaped to match the save payload. */
  selectedOptionIds: string[]

  /** numeric_input only. */
  numericQuantity: number | null

  /** extra_units only. */
  extraUnitsSelected: number | null

  /**
   * special_extra_product only. The stylist enters total grams used; units
   * are derived from `gramsPerUnit` at calc time. Stored as grams (not units)
   * so we can round-trip the exact input back into the UI.
   */
  specialExtraGrams: number | null
}

export type GuestQuoteDraft = {
  guestName: string
  notes: string
  /** Keyed by service.id. Missing entries are treated as an empty line. */
  lines: Record<string, GuestQuoteLineDraft>
}

export function emptyLineDraft(): GuestQuoteLineDraft {
  return {
    selected: false,
    selectedRole: null,
    selectedOptionIds: [],
    numericQuantity: null,
    extraUnitsSelected: null,
    specialExtraGrams: null,
  }
}

/**
 * Build a fresh, blank draft. No service is pre-selected; every line
 * starts empty. Callers with an existing draft and a refreshed config
 * should prefer `reconcileDraftWithConfig` so user edits survive refetches.
 */
export function emptyDraft(): GuestQuoteDraft {
  return {
    guestName: '',
    notes: '',
    lines: {},
  }
}

/**
 * Merge an existing draft against a new config: keeps lines for services
 * still present (by id); drops lines for services that have been archived
 * or deleted since the draft was built. Header fields are always kept.
 */
export function reconcileDraftWithConfig(
  prev: GuestQuoteDraft,
  config: StylistQuoteConfig,
): GuestQuoteDraft {
  const alive = new Set<string>()
  for (const sec of config.sections) {
    for (const svc of sec.services) alive.add(svc.id)
  }
  const nextLines: Record<string, GuestQuoteLineDraft> = {}
  for (const [id, line] of Object.entries(prev.lines)) {
    if (alive.has(id)) nextLines[id] = line
  }
  return { ...prev, lines: nextLines }
}

/** Return the existing draft line for a service, or a fresh blank one. */
export function lineFor(
  draft: GuestQuoteDraft,
  serviceId: string,
): GuestQuoteLineDraft {
  return draft.lines[serviceId] ?? emptyLineDraft()
}

/** Drop the line entry for a service, returning to the empty default. */
export function clearLine(
  draft: GuestQuoteDraft,
  serviceId: string,
): GuestQuoteDraft {
  if (!(serviceId in draft.lines)) return draft
  const nextLines = { ...draft.lines }
  delete nextLines[serviceId]
  return { ...draft, lines: nextLines }
}

/** Reset the whole form (header fields and all lines). */
export function resetDraft(): GuestQuoteDraft {
  return emptyDraft()
}

/**
 * Immutable update of a single line. `patch` is shallow-merged. If the
 * resulting line equals the empty line, the entry is removed so the
 * draft stays minimal / diff-friendly.
 */
export function updateLine(
  draft: GuestQuoteDraft,
  serviceId: string,
  patch: Partial<GuestQuoteLineDraft>,
): GuestQuoteDraft {
  const current = lineFor(draft, serviceId)
  const merged: GuestQuoteLineDraft = { ...current, ...patch }
  const nextLines = { ...draft.lines }
  if (isEmptyLine(merged)) {
    delete nextLines[serviceId]
  } else {
    nextLines[serviceId] = merged
  }
  return { ...draft, lines: nextLines }
}

export function isEmptyLine(line: GuestQuoteLineDraft): boolean {
  return (
    !line.selected &&
    line.selectedRole == null &&
    line.selectedOptionIds.length === 0 &&
    line.numericQuantity == null &&
    line.extraUnitsSelected == null &&
    line.specialExtraGrams == null
  )
}
