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
 * Convenience alias: the raw, per-line money amount for a service — the
 * same value that feeds the grand total and the save payload mapping.
 * Exposed so callers that need "just the number" don't have to destructure
 * the full `LinePricing` result, and so the difference from
 * `displayedRowTotal` (below) stays obvious at the call site.
 */
export function rawLineTotal(
  service: StylistQuoteService,
  line: GuestQuoteLineDraft,
): number {
  return priceForLine(service, line).lineTotal
}

/**
 * Map of `serviceId → displayed green amount` for every service in the
 * config, for the Guest Quote page's row display only. Grand total and
 * save payload continue to use the raw per-line totals from
 * `priceForLine` so this rollup is strictly cosmetic.
 *
 * Rules:
 *   1. Child vs. base is determined solely by
 *      `service.linkToBaseServiceId`. Services whose id matches
 *      another service's `linkToBaseServiceId` are bases; services
 *      with a non-null `linkToBaseServiceId` are children. No name
 *      or internal_key heuristics are used here.
 *   2. If a service has `linkToBaseServiceId` set, it is a child
 *      adjustment row. Its displayed amount is `null` — the row
 *      renders no standalone green price (or a neutral placeholder),
 *      and its raw line total is rolled up into the parent instead.
 *   3. For every other service (including services that have no
 *      children at all), the displayed amount is:
 *          rawLineTotal(self)  +  Σ rawLineTotal(children)
 *      where children are the services whose `linkToBaseServiceId`
 *      equals this service's id.
 *   4. If a child references a base id that isn't present in the
 *      current config (dangling link), we fall back to displaying
 *      the child's own amount so the total stays visible to the
 *      stylist. No guesswork.
 *
 * Defensive dev-only diagnostic: extra-unit / special-extra services
 * are *expected* to always have a `linkToBaseServiceId` — they're
 * adjustment rows on top of a parent service. If we encounter one
 * without a link, we log a warning so the config bug (usually a
 * dropped/NULL'd `link_to_base_service_id` column value for that
 * service) surfaces in the browser console instead of silently
 * behaving like a standalone service. Orphans are otherwise shown
 * as-is — we never infer a parent by name matching.
 *
 * Implementation is O(n): one pass to compute each service's raw line
 * total and bucket children by base id, then a second pass to sum
 * each base row's own total plus its children.
 */
export function buildDisplayedRowTotals(
  config: StylistQuoteConfig,
  draft: GuestQuoteDraft,
): Map<string, number | null> {
  const rawByService = new Map<string, number>()
  const childrenByBase = new Map<string, string[]>()
  const allServiceIds = new Set<string>()
  const orphanExtraServiceNames: string[] = []

  for (const section of config.sections) {
    for (const svc of section.services) {
      allServiceIds.add(svc.id)
      const line = lineFor(draft, svc.id)
      rawByService.set(svc.id, priceForLine(svc, line).lineTotal)
      const baseId = svc.linkToBaseServiceId
      if (baseId) {
        const list = childrenByBase.get(baseId) ?? []
        list.push(svc.id)
        childrenByBase.set(baseId, list)
      } else {
        // Only `extra_units` rows are expected to roll up into a base
        // row via `linkToBaseServiceId`. `special_extra_product` is a
        // standalone priced row (its own green total, its own visible
        // line) and must NOT require a link — so it is explicitly
        // excluded here and will never be classified as an orphan.
        //
        // For genuine extra_units children missing a link, display
        // continues to show their own total (no guessed parent), but
        // we flag them for the dev console below. The intended fix is
        // to set `link_to_base_service_id` via Quote Configuration.
        const shouldWarnMissingBaseLink =
          svc.inputType === 'extra_units' &&
          // Guard kept verbatim from the business-rule spec, even
          // though the outer union already rules this out at the type
          // level — documents intent and survives future additions to
          // `inputType`.
          (svc.inputType as string) !== 'special_extra_product' &&
          !svc.linkToBaseServiceId
        if (shouldWarnMissingBaseLink) {
          orphanExtraServiceNames.push(svc.name || svc.id)
        }
      }
    }
  }

  const out = new Map<string, number | null>()
  for (const section of config.sections) {
    for (const svc of section.services) {
      const childBaseId = svc.linkToBaseServiceId
      if (childBaseId) {
        if (!allServiceIds.has(childBaseId)) {
          // Dangling link: parent was archived or deleted. Keep the
          // child's own amount visible rather than swallowing it.
          out.set(svc.id, round2(rawByService.get(svc.id) ?? 0))
          continue
        }
        // Child linked rows do not display a standalone price —
        // their contribution is shown on the parent row instead.
        out.set(svc.id, null)
        continue
      }
      let total = rawByService.get(svc.id) ?? 0
      const childIds = childrenByBase.get(svc.id) ?? []
      for (const childId of childIds) {
        total += rawByService.get(childId) ?? 0
      }
      out.set(svc.id, round2(total))
    }
  }

  if (
    orphanExtraServiceNames.length > 0 &&
    typeof console !== 'undefined' &&
    typeof console.warn === 'function'
  ) {
    console.warn(
      '[GuestQuote] Extra-unit service(s) missing linkToBaseServiceId — ' +
        'displayed as standalone rows instead of rolling into a base. ' +
        'Fix via Quote Configuration → edit service → set "Link To Base Service": ' +
        orphanExtraServiceNames.join(', '),
    )
  }

  return out
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
