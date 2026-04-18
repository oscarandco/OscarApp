/**
 * Types for the admin-managed Quote Configuration.
 *
 * Shapes are designed to map cleanly to future Supabase tables:
 *   - quote_settings            (single row)
 *   - quote_sections            (pk: id)
 *   - quote_services            (pk: id, fk: section_id)
 *   - quote_service_options     (pk: id, fk: service_id)
 *   - quote_service_role_prices (fk: service_id; one row per role)
 * The MVP admin UI uses an in-memory store; wire via RPC/select later.
 */

export type QuoteRole = 'EMERGING' | 'SENIOR' | 'DIRECTOR' | 'MASTER'

/**
 * Canonical display order for roles across all admin Quote Configuration UI.
 * Left → right = junior → senior. Director is the most senior and appears last.
 * This is a display-only ordering; stored role values are unchanged.
 */
export const QUOTE_ROLES: readonly QuoteRole[] = [
  'EMERGING',
  'SENIOR',
  'MASTER',
  'DIRECTOR',
]

export function quoteRoleLabel(role: QuoteRole): string {
  switch (role) {
    case 'EMERGING':
      return 'Emerging'
    case 'SENIOR':
      return 'Senior'
    case 'DIRECTOR':
      return 'Director'
    case 'MASTER':
      return 'Master'
  }
}

/**
 * Return the given roles reordered to match QUOTE_ROLES (canonical display
 * order). Persisted order on quote_services.visible_roles may be arbitrary;
 * always run through this before rendering chips/columns.
 */
export function sortRolesCanonical(
  roles: readonly QuoteRole[],
): QuoteRole[] {
  const present = new Set(roles)
  return QUOTE_ROLES.filter((r) => present.has(r))
}

/** Service input control in stylist quote UI. */
export type QuoteInputType =
  | 'checkbox'
  | 'role_radio'
  | 'option_radio'
  | 'dropdown'
  | 'numeric_input'
  | 'extra_units'
  | 'special_extra_product'

export const QUOTE_INPUT_TYPES: readonly QuoteInputType[] = [
  'checkbox',
  'role_radio',
  'option_radio',
  'dropdown',
  'numeric_input',
  'extra_units',
  'special_extra_product',
]

export function quoteInputTypeLabel(t: QuoteInputType): string {
  switch (t) {
    case 'checkbox':
      return 'Checkbox'
    case 'role_radio':
      return 'Role radio'
    case 'option_radio':
      return 'Option radio'
    case 'dropdown':
      return 'Dropdown'
    case 'numeric_input':
      return 'Numeric input'
    case 'extra_units':
      return 'Extra units'
    case 'special_extra_product':
      return 'Special extra product'
  }
}

/** Pricing rule evaluated when a service is selected in a stylist quote. */
export type QuotePricingType =
  | 'fixed_price'
  | 'role_price'
  | 'option_price'
  | 'numeric_multiplier'
  | 'extra_unit_price'
  | 'special_extra_product'

export const QUOTE_PRICING_TYPES: readonly QuotePricingType[] = [
  'fixed_price',
  'role_price',
  'option_price',
  'numeric_multiplier',
  'extra_unit_price',
  'special_extra_product',
]

export function quotePricingTypeLabel(p: QuotePricingType): string {
  switch (p) {
    case 'fixed_price':
      return 'Fixed price'
    case 'role_price':
      return 'Role price'
    case 'option_price':
      return 'Option price'
    case 'numeric_multiplier':
      return 'Numeric multiplier'
    case 'extra_unit_price':
      return 'Extra unit price'
    case 'special_extra_product':
      return 'Special extra product'
  }
}

export function isRoleBasedPricing(p: QuotePricingType): boolean {
  return p === 'role_price'
}

export function isOptionBasedPricing(p: QuotePricingType): boolean {
  return p === 'option_price'
}

export function isOptionBasedInput(t: QuoteInputType): boolean {
  return t === 'option_radio' || t === 'dropdown'
}

export function isNumericPricing(p: QuotePricingType): boolean {
  return p === 'numeric_multiplier'
}

export function isExtraUnitPricing(p: QuotePricingType): boolean {
  return p === 'extra_unit_price'
}

export function isSpecialExtraProductPricing(p: QuotePricingType): boolean {
  return p === 'special_extra_product'
}

/** Global quote settings — single editable record. */
export type QuoteSettings = {
  greenFeeAmount: number
  notesEnabled: boolean
  guestNameRequired: boolean
  quotePageTitle: string
  active: boolean
  updatedAt: string
}

export type QuoteSection = {
  id: string
  name: string
  summaryLabel: string
  displayOrder: number
  active: boolean
  sectionHelpText: string | null
  usedInSavedQuotes: boolean
  createdAt: string
  updatedAt: string
}

export type QuoteServiceOption = {
  id: string
  label: string
  valueKey: string
  displayOrder: number
  active: boolean
  /** Used when the parent service is option_price. Kept null for option-input + fixed price. */
  price: number | null
}

/** Per-role price for role_price services. Keys are fixed role labels. */
export type QuoteRolePriceMap = Partial<Record<QuoteRole, number | null>>

export type NumericMultiplierConfig = {
  unitLabel: string
  pricePerUnit: number
  min: number
  max: number
  step: number
  defaultValue: number
  roundTo: number | null
  minCharge: number | null
}

export type ExtraUnitConfig = {
  baseIncludedAmountLabel: string | null
  extraLabel: string
  extraUnitDisplaySuffix: string | null
  pricePerExtraUnit: number
  maxExtras: number
  /** Locked to `radio_1_to_n` in MVP. */
  optionStyle: 'radio_1_to_n'
  linkToBaseServiceId: string | null
}

export type SpecialExtraProductConfig = {
  /**
   * @deprecated Legacy field from the multi-row calculator design.
   * Special Extra Product is now rendered as a single standalone row on
   * the Guest Quote page (one numeric grams input), so this is always
   * treated as `1` end-to-end. The field is still round-tripped through
   * load/save so old config rows and the `save_guest_quote` RPC's
   * row-count validation continue to work unchanged.
   */
  numberOfRows: number
  /**
   * @deprecated Legacy per-row cap from the multi-row calculator.
   * Retained for backward compatibility only: the Guest Quote sends a
   * single row and the `save_guest_quote` RPC still validates each
   * row's units against this value. Not exposed in the admin drawer
   * anymore — existing values round-trip untouched; new services
   * default to a large cap that never constrains realistic input.
   */
  maxUnitsPerRow: number
  pricePerUnit: number
  gramsPerUnit: number
  minutesPerUnit: number
  blueSummaryLabelTemplate: string
}

export type QuoteService = {
  id: string
  sectionId: string
  name: string
  internalKey: string | null
  active: boolean
  displayOrder: number
  helpText: string | null
  summaryLabelOverride: string | null

  inputType: QuoteInputType
  pricingType: QuotePricingType

  visibleRoles: QuoteRole[]
  options: QuoteServiceOption[]

  fixedPrice: number | null
  rolePrices: QuoteRolePriceMap
  numeric: NumericMultiplierConfig | null
  extraUnit: ExtraUnitConfig | null
  specialExtra: SpecialExtraProductConfig | null

  includeInQuoteSummary: boolean
  summaryGroupOverride: string | null
  adminNotes: string | null

  usedInSavedQuotes: boolean
  createdAt: string
  updatedAt: string
}

export type QuoteConfiguration = {
  settings: QuoteSettings
  sections: QuoteSection[]
  services: QuoteService[]
}

/** Default values used when creating a new service via the drawer. */
export function defaultNumericMultiplier(): NumericMultiplierConfig {
  return {
    unitLabel: 'unit',
    pricePerUnit: 0,
    min: 0,
    max: 10,
    step: 1,
    defaultValue: 0,
    roundTo: null,
    minCharge: null,
  }
}

export function defaultExtraUnit(): ExtraUnitConfig {
  return {
    baseIncludedAmountLabel: null,
    extraLabel: 'Extra',
    extraUnitDisplaySuffix: null,
    pricePerExtraUnit: 0,
    maxExtras: 5,
    optionStyle: 'radio_1_to_n',
    linkToBaseServiceId: null,
  }
}

export function defaultSpecialExtraProduct(): SpecialExtraProductConfig {
  // Guest Quote sends a single row and validates only a single numeric
  // grams input. `numberOfRows` is locked to 1; `maxUnitsPerRow` is set
  // generously high so the `save_guest_quote` RPC's row-cap validation
  // never rejects realistic input. These two fields are deprecated —
  // retained for backward compatibility only, see
  // `SpecialExtraProductConfig` above.
  return {
    numberOfRows: 1,
    maxUnitsPerRow: 999,
    pricePerUnit: 0,
    gramsPerUnit: 18,
    minutesPerUnit: 10,
    blueSummaryLabelTemplate: '{units} units / {grams} grams or {minutes} mins',
  }
}

/** Build a slug for internal key fallback. */
export function slugifyInternalKey(source: string): string {
  return source
    .toLowerCase()
    .replace(/['"]/g, '')
    .replace(/[^a-z0-9]+/g, '_')
    .replace(/^_+|_+$/g, '')
    .slice(0, 60)
}
