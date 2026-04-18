/**
 * Types for the stylist-facing Guest Quote page read model.
 *
 * This is deliberately a reduced/cleaned-up view of the admin Quote
 * Configuration types — shared primitives (roles, input/pricing enums,
 * JSONB config shapes) are re-exported from `@/features/admin/types/
 * quoteConfiguration` so there is a single source of truth, while admin-only
 * metadata (created_at / updated_at / admin_notes / active flags / etc.) is
 * intentionally omitted.
 *
 * Data shape mirrors the JSONB payload returned by the public
 * `get_active_quote_config()` RPC.
 */

import type {
  ExtraUnitConfig,
  NumericMultiplierConfig,
  QuoteInputType,
  QuotePricingType,
  QuoteRole,
  QuoteRolePriceMap,
  SpecialExtraProductConfig,
} from '@/features/admin/types/quoteConfiguration'

export type {
  ExtraUnitConfig,
  NumericMultiplierConfig,
  QuoteInputType,
  QuotePricingType,
  QuoteRole,
  QuoteRolePriceMap,
  SpecialExtraProductConfig,
}

export type StylistQuoteSettings = {
  greenFeeAmount: number
  notesEnabled: boolean
  guestNameRequired: boolean
  quotePageTitle: string
  active: boolean
}

export type StylistQuoteOption = {
  id: string
  label: string
  valueKey: string
  displayOrder: number
  /** Populated when the parent service has pricing_type = option_price. */
  price: number | null
}

export type StylistQuoteService = {
  id: string
  sectionId: string
  name: string
  internalKey: string | null
  displayOrder: number
  helpText: string | null
  summaryLabelOverride: string | null

  inputType: QuoteInputType
  pricingType: QuotePricingType

  visibleRoles: QuoteRole[]

  fixedPrice: number | null
  rolePrices: QuoteRolePriceMap
  numeric: NumericMultiplierConfig | null
  extraUnit: ExtraUnitConfig | null
  specialExtra: SpecialExtraProductConfig | null
  /**
   * Promoted out of `extra_unit_config` into its own FK-enforced column on
   * the server; exposed at service level for the stylist page so linked
   * extras can resolve their base service without unwrapping the JSONB.
   */
  linkToBaseServiceId: string | null

  includeInQuoteSummary: boolean
  summaryGroupOverride: string | null

  options: StylistQuoteOption[]
}

export type StylistQuoteSection = {
  id: string
  name: string
  summaryLabel: string
  displayOrder: number
  sectionHelpText: string | null
  services: StylistQuoteService[]
}

export type StylistQuoteConfig = {
  settings: StylistQuoteSettings
  sections: StylistQuoteSection[]
}
