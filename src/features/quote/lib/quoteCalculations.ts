/**
 * Pure, server-independent pricing/summary helpers for the stylist Guest
 * Quote page. Kept in a dedicated module so the page component stays thin
 * and so these rules are easy to unit-test once save lands.
 *
 * Pricing rules here mirror the authoritative logic in the
 * `save_guest_quote(payload jsonb)` Postgres function (see
 * supabase/migrations/20260501180000_save_guest_quote_rpc.sql). The server
 * is the source of truth at save time; the frontend computes a running
 * total for UX only.
 */

import type {
  StylistQuoteConfig,
  StylistQuoteSection,
  StylistQuoteService,
} from '@/features/quote/types/stylistQuoteConfig'
import type {
  GuestQuoteDraft,
  GuestQuoteLineDraft,
} from '@/features/quote/state/guestQuoteDraft'
import { lineFor } from '@/features/quote/state/guestQuoteDraft'

/** Rounded-to-cents helper used throughout to avoid float dust. */
function round2(n: number): number {
  return Math.round(n * 100) / 100
}

/**
 * Extra info produced alongside the money total for special_extra_product
 * lines — useful for the input control's "X units / Y grams / Z mins"
 * caption.
 */
export type SpecialExtraDerived = {
  units: number
  grams: number
  minutes: number
}

export type LinePricing = {
  lineTotal: number
  /**
   * Present for special_extra_product only. null for all other pricing
   * types — callers just display the total.
   */
  specialExtra: SpecialExtraDerived | null
}

const EMPTY_LINE: LinePricing = { lineTotal: 0, specialExtra: null }

/**
 * Compute the line total for a single service given the stylist's draft
 * for that service. Returns zero for unselected / invalid states rather
 * than throwing — the form is expected to guide users to valid input.
 */
export function priceForLine(
  service: StylistQuoteService,
  line: GuestQuoteLineDraft,
): LinePricing {
  if (!line.selected) return EMPTY_LINE

  switch (service.pricingType) {
    case 'fixed_price': {
      const p = service.fixedPrice ?? 0
      return { lineTotal: round2(p), specialExtra: null }
    }

    case 'role_price': {
      const role = line.selectedRole
      if (!role) return EMPTY_LINE
      const p = service.rolePrices[role] ?? 0
      return { lineTotal: round2(p ?? 0), specialExtra: null }
    }

    case 'option_price': {
      if (line.selectedOptionIds.length === 0) return EMPTY_LINE
      let total = 0
      for (const optId of line.selectedOptionIds) {
        const opt = service.options.find((o) => o.id === optId)
        if (opt?.price != null) total += opt.price
      }
      return { lineTotal: round2(total), specialExtra: null }
    }

    case 'numeric_multiplier': {
      const cfg = service.numeric
      const qty = line.numericQuantity
      if (!cfg || qty == null || qty <= 0) return EMPTY_LINE
      let total = qty * cfg.pricePerUnit
      if (cfg.roundTo != null && cfg.roundTo > 0) {
        total = Math.round(total / cfg.roundTo) * cfg.roundTo
      }
      if (cfg.minCharge != null && total < cfg.minCharge) total = cfg.minCharge
      return { lineTotal: round2(total), specialExtra: null }
    }

    case 'extra_unit_price': {
      const cfg = service.extraUnit
      const units = line.extraUnitsSelected
      if (!cfg || units == null || units <= 0) return EMPTY_LINE
      return {
        lineTotal: round2(units * cfg.pricePerExtraUnit),
        specialExtra: null,
      }
    }

    case 'special_extra_product': {
      const cfg = service.specialExtra
      const grams = line.specialExtraGrams
      if (!cfg || grams == null || grams <= 0) return EMPTY_LINE
      const gramsPerUnit = cfg.gramsPerUnit > 0 ? cfg.gramsPerUnit : 1
      const units = Math.ceil(grams / gramsPerUnit)
      const minutes = units * cfg.minutesPerUnit
      return {
        lineTotal: round2(units * cfg.pricePerUnit),
        specialExtra: { units, grams, minutes },
      }
    }

    default:
      return EMPTY_LINE
  }
}

/**
 * Decide the summary group label for a selected service.
 *
 * UI-side grouping rule (per task brief):
 *   summaryGroupOverride → summaryLabelOverride → section.summaryLabel
 *
 * NOTE: the server's `save_guest_quote` stores grouping per line with a
 * slightly different priority (summary_label_override → summary_group_override
 * → section.summary_label). The saved receipt rolls up section totals by
 * section_id, so the divergence is display-only and intentional here.
 */
export function summaryGroupFor(
  service: StylistQuoteService,
  section: StylistQuoteSection,
): string {
  const override =
    trimToNull(service.summaryGroupOverride) ??
    trimToNull(service.summaryLabelOverride) ??
    trimToNull(section.summaryLabel) ??
    section.name
  return override
}

function trimToNull(s: string | null | undefined): string | null {
  if (s == null) return null
  const t = s.trim()
  return t === '' ? null : t
}

/**
 * Label shown for a single service row inside the summary panel. Uses the
 * service's `summaryLabelOverride` when set, otherwise the service name.
 */
export function summaryRowLabelFor(service: StylistQuoteService): string {
  return trimToNull(service.summaryLabelOverride) ?? service.name
}

export type SummaryRow = {
  serviceId: string
  label: string
  lineTotal: number
  /** Populated for special_extra_product so the panel can show "x units". */
  specialExtra: SpecialExtraDerived | null
}

export type SummaryGroup = {
  /** Stable key used for React lists / sorting; same as `label`. */
  key: string
  label: string
  rows: SummaryRow[]
  subtotal: number
  /** Lowest section.displayOrder contributing — used for stable sort. */
  sortOrder: number
}

export type QuoteSummary = {
  groups: SummaryGroup[]
  /** Sum of all line totals (excludes green fee). */
  linesTotal: number
  greenFee: number
  grandTotal: number
}

/**
 * Build the full summary for the current draft. Services whose config
 * flag `includeInQuoteSummary` is false are omitted from the summary
 * panel but still contribute to the running grand total — same rule
 * the server applies in `save_guest_quote`. (That rule is preserved
 * here even though the current config surfaces nothing that opts out.)
 *
 * Green Fee is always included as its own group/row.
 */
export function buildQuoteSummary(
  config: StylistQuoteConfig,
  draft: GuestQuoteDraft,
): QuoteSummary {
  const groupMap = new Map<string, SummaryGroup>()
  let linesTotal = 0

  for (const section of config.sections) {
    for (const service of section.services) {
      const line = lineFor(draft, service.id)
      const pricing = priceForLine(service, line)
      if (pricing.lineTotal <= 0) continue

      linesTotal += pricing.lineTotal

      if (!service.includeInQuoteSummary) continue

      const groupLabel = summaryGroupFor(service, section)
      let group = groupMap.get(groupLabel)
      if (!group) {
        group = {
          key: groupLabel,
          label: groupLabel,
          rows: [],
          subtotal: 0,
          sortOrder: section.displayOrder,
        }
        groupMap.set(groupLabel, group)
      } else if (section.displayOrder < group.sortOrder) {
        group.sortOrder = section.displayOrder
      }
      group.rows.push({
        serviceId: service.id,
        label: summaryRowLabelFor(service),
        lineTotal: pricing.lineTotal,
        specialExtra: pricing.specialExtra,
      })
      group.subtotal = round2(group.subtotal + pricing.lineTotal)
    }
  }

  const groups = Array.from(groupMap.values()).sort(
    (a, b) => a.sortOrder - b.sortOrder,
  )

  const greenFee = round2(config.settings.greenFeeAmount)
  const grandTotal = round2(linesTotal + greenFee)

  return {
    groups,
    linesTotal: round2(linesTotal),
    greenFee,
    grandTotal,
  }
}
