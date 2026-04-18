/**
 * Requote helper: map a saved quote's detail payload into a fresh
 * Guest Quote draft, resolved against the *current* live quote
 * configuration.
 *
 * Important rules
 * ---------------
 * - The original saved quote is never touched. This is purely a client
 *   mapping into the existing `GuestQuoteDraft` shape used by the Guest
 *   Quote page.
 * - Config drift is expected. Services, sections and options may have
 *   been renamed, archived or deleted since the quote was saved. The
 *   mapper is intentionally forgiving:
 *     * lines that cannot be matched to a current service are skipped
 *       entirely and reported in `skippedServiceNames`
 *     * for a kept line, any options that can't be matched by
 *       `valueKey` against the current service are simply dropped and
 *       the service name is reported in `skippedServiceNames` too (so
 *       the stylist is nudged to review before submitting)
 * - Matching strategy (best-effort, name-based since the detail RPC
 *   does not expose `service_id`):
 *     1. saved `section_id` + saved `service_name` against current
 *        config (exact, case-insensitive, trimmed)
 *     2. saved `service_name` across all sections (exact, case-
 *        insensitive, trimmed) — only if a single candidate exists
 *   Ambiguous or missing matches are treated as drift and skipped.
 * - Options are matched by saved `value_key` against the current
 *   service's `options[].valueKey` (also case-insensitive, trimmed).
 */

import type { QuoteRole } from '@/features/admin/types/quoteConfiguration'
import { QUOTE_ROLES } from '@/features/admin/types/quoteConfiguration'
import {
  emptyDraft,
  emptyLineDraft,
  type GuestQuoteDraft,
  type GuestQuoteLineDraft,
} from '@/features/quote/state/guestQuoteDraft'
import type {
  SavedQuoteDetail,
  SavedQuoteDetailLine,
  SavedQuoteDetailSelectedOption,
} from '@/features/quote/types/savedQuoteDetail'
import type {
  StylistQuoteConfig,
  StylistQuoteService,
} from '@/features/quote/types/stylistQuoteConfig'

/**
 * Payload passed via `react-router`'s `location.state` from the Quote
 * Detail page to the Guest Quote page. Kept intentionally small and
 * serializable so it survives a history restore.
 */
export type RequoteNavState = {
  /** Discriminator so the Guest Quote page can spot this state shape. */
  kind: 'requote-from-saved'
  /** Saved quote id this requote was sourced from — informational only. */
  sourceSavedQuoteId: string
  /** The full detail payload as the user just saw it on the detail page. */
  detail: SavedQuoteDetail
}

export type RequoteMappingResult = {
  draft: GuestQuoteDraft
  /**
   * Service names from the saved quote that either could not be matched
   * to a current service at all, or whose options drifted enough that
   * the stylist should double-check them before submitting. Deduped and
   * stable-ordered (insertion order from the saved lines).
   */
  skippedServiceNames: string[]
}

function normalise(s: string | null | undefined): string {
  return (s ?? '').trim().toLowerCase()
}

function isQuoteRole(value: string | null): value is QuoteRole {
  if (!value) return false
  return (QUOTE_ROLES as readonly string[]).includes(value)
}

/**
 * Find the current service for a saved line.
 *
 *   1. prefer a match within the saved line's original section (if the
 *      section still exists) — protects against two sections having
 *      services with the same name.
 *   2. otherwise accept a single unique match by service name across
 *      the whole config.
 *   3. anything else is drift and returns null.
 */
function resolveService(
  line: SavedQuoteDetailLine,
  config: StylistQuoteConfig,
): StylistQuoteService | null {
  const targetName = normalise(line.serviceName)
  if (!targetName) return null

  if (line.sectionId) {
    const section = config.sections.find((s) => s.id === line.sectionId)
    if (section) {
      const inSection = section.services.filter(
        (s) => normalise(s.name) === targetName,
      )
      if (inSection.length === 1) return inSection[0] ?? null
      if (inSection.length > 1) return null // ambiguous within section
    }
  }

  const across: StylistQuoteService[] = []
  for (const section of config.sections) {
    for (const service of section.services) {
      if (normalise(service.name) === targetName) across.push(service)
    }
  }
  return across.length === 1 ? across[0] ?? null : null
}

/**
 * Resolve saved options (by `value_key`) against the current service's
 * options. Returns the current option ids, and whether any saved option
 * was lost in the process.
 */
function resolveOptionIds(
  saved: SavedQuoteDetailSelectedOption[],
  service: StylistQuoteService,
): { optionIds: string[]; dropped: boolean } {
  if (saved.length === 0) return { optionIds: [], dropped: false }
  const byValueKey = new Map<string, string>()
  for (const opt of service.options) {
    byValueKey.set(normalise(opt.valueKey), opt.id)
  }
  const optionIds: string[] = []
  let dropped = false
  for (const s of saved) {
    const id = byValueKey.get(normalise(s.valueKey))
    if (id) optionIds.push(id)
    else dropped = true
  }
  return { optionIds, dropped }
}

/** Sum the `grams` values from the saved special-extra rows payload. */
function sumSpecialExtraGrams(raw: unknown): number | null {
  if (!Array.isArray(raw)) return null
  let total = 0
  let anyNumeric = false
  for (const row of raw) {
    if (row && typeof row === 'object') {
      const g = Number((row as Record<string, unknown>).grams ?? 0)
      if (Number.isFinite(g) && g > 0) {
        total += g
        anyNumeric = true
      }
    }
  }
  return anyNumeric ? total : null
}

/**
 * Build a single line draft for a resolved service + saved line.
 *
 * We populate every draft field the saved line has data for, regardless
 * of the current service's input/pricing type — the calculator only
 * reads the fields relevant to the current type, so any drift between
 * the saved line's type and the current type is harmless noise rather
 * than corrupt state. Worst case: a field gets ignored on recalculation
 * and the stylist reviews + adjusts before submit.
 */
function buildLineDraft(
  service: StylistQuoteService,
  line: SavedQuoteDetailLine,
): { line: GuestQuoteLineDraft; optionsDropped: boolean } {
  const out = emptyLineDraft()
  out.selected = true

  if (isQuoteRole(line.selectedRole)) {
    out.selectedRole = line.selectedRole
  }

  const { optionIds, dropped } = resolveOptionIds(line.selectedOptions, service)
  out.selectedOptionIds = optionIds

  if (line.numericQuantity != null && Number.isFinite(line.numericQuantity)) {
    out.numericQuantity = line.numericQuantity
  }
  if (
    line.extraUnitsSelected != null &&
    Number.isFinite(line.extraUnitsSelected)
  ) {
    out.extraUnitsSelected = line.extraUnitsSelected
  }

  const grams = sumSpecialExtraGrams(line.specialExtraRows)
  if (grams != null) out.specialExtraGrams = grams

  return { line: out, optionsDropped: dropped }
}

/**
 * Top-level mapper. Given the saved quote detail the user just looked
 * at, produce a fresh Guest Quote draft seeded from it, plus a list of
 * service names the stylist should double-check because of drift.
 *
 * Never throws: callers can treat the result as "best-effort prefill"
 * and render the Guest Quote page normally even if the result is an
 * empty draft.
 */
export function buildRequoteDraftFromSaved(
  detail: SavedQuoteDetail,
  config: StylistQuoteConfig,
): RequoteMappingResult {
  const draft = emptyDraft()
  draft.guestName = detail.header.guestName ?? ''
  draft.notes = detail.header.notes ?? ''

  const skipped: string[] = []
  const seenSkipped = new Set<string>()
  const pushSkipped = (name: string) => {
    const trimmed = name.trim() || 'Unnamed service'
    if (seenSkipped.has(trimmed)) return
    seenSkipped.add(trimmed)
    skipped.push(trimmed)
  }

  for (const line of detail.lines) {
    const service = resolveService(line, config)
    if (!service) {
      pushSkipped(line.serviceName)
      continue
    }

    const { line: lineDraft, optionsDropped } = buildLineDraft(service, line)
    // Two saved lines can legitimately map onto the same current
    // service after drift (e.g. a renamed duplicate was merged). If
    // that happens, keep the first mapping and warn on the second so
    // the stylist sees we couldn't faithfully replay both.
    if (draft.lines[service.id]) {
      pushSkipped(line.serviceName)
      continue
    }
    draft.lines[service.id] = lineDraft

    if (optionsDropped) pushSkipped(service.name)
  }

  return { draft, skippedServiceNames: skipped }
}
