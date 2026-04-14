/** Matches `public.remuneration_plan_rates.commission_category` check constraint. */
export const REMUNERATION_STANDARD_COMMISSION_CATEGORIES = [
  'retail_product',
  'professional_product',
  'service',
] as const

/** Header-matched or special classifications (see sales view `commission_category_final`). */
export const REMUNERATION_PLAN_SPECIFIC_COMMISSION_CATEGORIES = [
  'toner_with_other_service',
  'extensions_product',
  'extensions_service',
] as const

export const REMUNERATION_COMMISSION_CATEGORIES = [
  ...REMUNERATION_STANDARD_COMMISSION_CATEGORIES,
  ...REMUNERATION_PLAN_SPECIFIC_COMMISSION_CATEGORIES,
] as const

export type RemunerationCommissionCategory =
  (typeof REMUNERATION_COMMISSION_CATEGORIES)[number]

/** UI labels (order matches DB categories). */
export const REMUNERATION_CATEGORY_LABEL: Record<
  RemunerationCommissionCategory,
  string
> = {
  retail_product: 'Retail product %',
  professional_product: 'Professional product %',
  service: 'Service %',
  toner_with_other_service: 'Toner with other service %',
  extensions_product: 'Extensions product %',
  extensions_service: 'Extensions service %',
}

/** Short titles for card headers (no % suffix). */
export const REMUNERATION_CATEGORY_CARD_TITLE: Record<
  RemunerationCommissionCategory,
  string
> = {
  retail_product: 'Retail product',
  professional_product: 'Professional product',
  service: 'Service',
  toner_with_other_service: 'Toner with other service',
  extensions_product: 'Extensions product',
  extensions_service: 'Extensions service',
}

/**
 * Helper copy aligned with `v_sales_transactions_powerbi_parity` / payroll views:
 * rates are multiplied by ex GST line value when `commission_category_final` matches.
 */
export const REMUNERATION_CATEGORY_DESCRIPTION: Record<
  RemunerationCommissionCategory,
  string
> = {
  retail_product:
    'Applied when a line is classified as retail product (from product master or import, excluding professional * lines).',
  professional_product:
    'Applied when a line is classified as professional product (including lines marked with * on the product name).',
  service:
    'Applied when a line is classified as a service from product type / master data.',
  toner_with_other_service:
    'Applied when the product header matches toner-with-other-service rules; those lines take this commission category and this percentage of ex GST.',
  extensions_product:
    'Applied when the product header matches bonded/extensions product rules; those lines use this rate × ex GST.',
  extensions_service:
    'Applied when the product header matches extensions service (e.g. tapes) rules; those lines use this rate × ex GST.',
}

export const REMUNERATION_CAN_USE_ASSISTANTS_DESCRIPTION =
  'When enabled, assistants can be paid commission on eligible lines according to staff roles and the imported sale. When disabled, assistant usage on this plan is flagged as ineligible.'

export type RemunerationPlanRow = {
  id: string
  plan_name: string
  can_use_assistants: boolean | null
  conditions_text: string | null
  staff_on_this_plan_text: string | null
  is_active: boolean
  created_at: string
  updated_at: string
}

export type RemunerationPlanRateRow = {
  id: string
  remuneration_plan_id: string
  commission_category: string
  rate: string | number
  created_at: string
  updated_at: string
}

export type RemunerationPlanWithRates = RemunerationPlanRow & {
  rates: RemunerationPlanRateRow[]
}

export type StaffOnPlanRow = {
  staff_member_id: string
  display_name: string | null
  full_name: string
  is_active: boolean
}
