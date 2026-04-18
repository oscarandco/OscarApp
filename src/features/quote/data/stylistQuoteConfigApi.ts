/**
 * Supabase data layer for the stylist-facing Guest Quote page.
 *
 * Reads route through the SECURITY DEFINER RPC `public.get_active_quote_config()`,
 * which returns a single JSONB tree of active settings / sections / services /
 * options / role prices. The RPC enforces `auth.uid() IS NOT NULL`; this file
 * never hits the underlying tables directly.
 */
import type { PostgrestError } from '@supabase/supabase-js'

import {
  QUOTE_ROLES,
  type QuoteInputType,
  type QuotePricingType,
  type QuoteRole,
} from '@/features/admin/types/quoteConfiguration'
import type {
  ExtraUnitConfig,
  NumericMultiplierConfig,
  QuoteRolePriceMap,
  SpecialExtraProductConfig,
  StylistQuoteConfig,
  StylistQuoteOption,
  StylistQuoteSection,
  StylistQuoteService,
  StylistQuoteSettings,
} from '@/features/quote/types/stylistQuoteConfig'
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
  return typeof v === 'string' ? v : String(v)
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

function asStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return []
  return v.filter((x): x is string => typeof x === 'string')
}

function mapSettings(row: Row | null): StylistQuoteSettings {
  const r = row ?? {}
  return {
    greenFeeAmount: asNumber(r.green_fee_amount),
    notesEnabled: asBool(r.notes_enabled, true),
    guestNameRequired: asBool(r.guest_name_required, false),
    quotePageTitle: asString(r.quote_page_title) || 'Guest Quote',
    active: asBool(r.active, false),
  }
}

function mapNumericConfig(v: unknown): NumericMultiplierConfig | null {
  const o = asObject(v)
  if (!o) return null
  return {
    unitLabel: asString(o.unitLabel) || 'unit',
    pricePerUnit: asNumber(o.pricePerUnit),
    min: asNumber(o.min),
    max: asNumber(o.max),
    step: asNumber(o.step) || 1,
    defaultValue: asNumber(o.defaultValue),
    roundTo: asNumberOrNull(o.roundTo),
    minCharge: asNumberOrNull(o.minCharge),
  }
}

function mapExtraUnitConfig(v: unknown): ExtraUnitConfig | null {
  const o = asObject(v)
  if (!o) return null
  return {
    baseIncludedAmountLabel: asStringOrNull(o.baseIncludedAmountLabel),
    extraLabel: asString(o.extraLabel) || 'Extra',
    extraUnitDisplaySuffix: asStringOrNull(o.extraUnitDisplaySuffix),
    pricePerExtraUnit: asNumber(o.pricePerExtraUnit),
    maxExtras: asNumber(o.maxExtras),
    optionStyle: 'radio_1_to_n',
    linkToBaseServiceId: asStringOrNull(o.linkToBaseServiceId),
  }
}

function mapSpecialExtraConfig(v: unknown): SpecialExtraProductConfig | null {
  const o = asObject(v)
  if (!o) return null
  return {
    numberOfRows: asNumber(o.numberOfRows),
    maxUnitsPerRow: asNumber(o.maxUnitsPerRow),
    pricePerUnit: asNumber(o.pricePerUnit),
    gramsPerUnit: asNumber(o.gramsPerUnit),
    minutesPerUnit: asNumber(o.minutesPerUnit),
    blueSummaryLabelTemplate:
      asString(o.blueSummaryLabelTemplate) ||
      '{units} units / {grams} grams or {minutes} mins',
  }
}

function mapRolePrices(v: unknown): QuoteRolePriceMap {
  const o = asObject(v)
  if (!o) return {}
  const out: QuoteRolePriceMap = {}
  for (const [k, val] of Object.entries(o)) {
    const role = k as QuoteRole
    if (QUOTE_ROLES.includes(role)) {
      out[role] = asNumberOrNull(val)
    }
  }
  return out
}

function mapOption(row: Row): StylistQuoteOption {
  return {
    id: asString(row.id),
    label: asString(row.label),
    valueKey: asString(row.value_key),
    displayOrder: asNumber(row.display_order),
    price: asNumberOrNull(row.price),
  }
}

function mapService(row: Row): StylistQuoteService {
  return {
    id: asString(row.id),
    sectionId: asString(row.section_id),
    name: asString(row.name),
    internalKey: asStringOrNull(row.internal_key),
    displayOrder: asNumber(row.display_order),
    helpText: asStringOrNull(row.help_text),
    summaryLabelOverride: asStringOrNull(row.summary_label_override),
    inputType: asString(row.input_type) as QuoteInputType,
    pricingType: asString(row.pricing_type) as QuotePricingType,
    visibleRoles: asStringArray(row.visible_roles).filter((r): r is QuoteRole =>
      QUOTE_ROLES.includes(r as QuoteRole),
    ),
    fixedPrice: asNumberOrNull(row.fixed_price),
    rolePrices: mapRolePrices(row.role_prices),
    numeric: mapNumericConfig(row.numeric_config),
    extraUnit: mapExtraUnitConfig(row.extra_unit_config),
    specialExtra: mapSpecialExtraConfig(row.special_extra_config),
    linkToBaseServiceId: asStringOrNull(row.link_to_base_service_id),
    includeInQuoteSummary: asBool(row.include_in_quote_summary, true),
    summaryGroupOverride: asStringOrNull(row.summary_group_override),
    options: asArray(row.options)
      .map((o) => mapOption(asObject(o) ?? {}))
      .sort((a, b) => a.displayOrder - b.displayOrder),
  }
}

function mapSection(row: Row): StylistQuoteSection {
  return {
    id: asString(row.id),
    name: asString(row.name),
    summaryLabel: asString(row.summary_label),
    displayOrder: asNumber(row.display_order),
    sectionHelpText: asStringOrNull(row.section_help_text),
    services: asArray(row.services)
      .map((s) => mapService(asObject(s) ?? {}))
      .sort((a, b) => a.displayOrder - b.displayOrder),
  }
}

function mapPayload(payload: unknown): StylistQuoteConfig {
  const root = asObject(payload)
  return {
    settings: mapSettings(root ? asObject(root.settings) : null),
    sections: asArray(root?.sections)
      .map((s) => mapSection(asObject(s) ?? {}))
      .sort((a, b) => a.displayOrder - b.displayOrder),
  }
}

/**
 * Load the full active Guest Quote configuration via the SECURITY DEFINER
 * RPC. Returns a ready-to-render tree; callers do not need to do any further
 * filtering for `active` (the RPC already excludes archived rows).
 */
export async function fetchStylistQuoteConfig(): Promise<StylistQuoteConfig> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_active_quote_config',
  )
  if (error) throw toError('get_active_quote_config', error)
  return mapPayload(data)
}
