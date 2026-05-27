/**
 * TypeScript view of the jsonb envelope returned by
 * `public.get_staff_commission_guide(p_staff_member_id, p_as_of_date)`.
 *
 * Keep this in sync with the migration at
 * `supabase/migrations/20260828120500_commission_guide.sql`.
 */

/** Wage / commission categories used by `remuneration_plan_rates`. */
export type CommissionRateCategory =
  | 'service'
  | 'retail_product'
  | 'professional_product'
  | 'toner_with_other_service'
  | 'extensions_product'
  | 'extensions_service'

/** Non-payable buckets reported by the parity view / payroll status. */
export type CommissionNoCommissionCategory =
  | 'no_commission_voucher'
  | 'no_commission_greenfee'
  | 'no_commission_redo'
  | 'no_commission_trainingproduct'
  | 'no_commission_miscellaneousproduct'
  | 'no_commission_unclassified'

/** Any string the RPC may emit in `commission_category`. */
export type CommissionCategoryAny =
  | CommissionRateCategory
  | CommissionNoCommissionCategory
  | string
  | null

export type CommissionGuideStaff = {
  staff_member_id: string
  display_name: string | null
  full_name: string | null
  is_active: boolean
  primary_role: string | null
  secondary_roles: string | null
  employment_type: string | null
  fte: number | string | null
  primary_location_id: string | null
  primary_location_name: string | null
  remuneration_plan: string | null
  /** Effective start of the assignment the rest of the envelope is built from. Null when falling back to `staff_members`. */
  effective_start_date: string | null
}

export type CommissionGuidePlanSummary = {
  headline: string
  plain_english: string
  important_notes: string[]
  /** True when no staff_role_assignments row covered the as-of date and the RPC fell back to staff_members. */
  using_fallback_to_current_profile: boolean
}

export type CommissionGuideRateCard = {
  label: string
  category: CommissionRateCategory
  rate: number | null
  has_rate: boolean
  plain_english: string
}

export type CommissionGuideClassificationRow = {
  product_or_category: string
  imported_type: string | null
  configured_system_type: string | null
  configured_product_type: string | null
  commission_category: CommissionCategoryAny
  rate_for_this_plan: number | null
  counts_for_commission: boolean
  plain_english: string
}

export type CommissionGuideExclusion = {
  label: string
  commission_category: CommissionNoCommissionCategory | string
  plain_english: string
}

export type CommissionGuideSpecialCase = {
  label: string
  rule_key: string
  plain_english: string
}

export type CommissionGuideExample = {
  label: string
  sale_ex_gst: number
  rate: number | null
  commission: number
  category: CommissionCategoryAny
  plain_english: string
}

export type CommissionGuidePlan = {
  id: string
  plan_name: string
  can_use_assistants: boolean | null
  conditions_text: string | null
  staff_on_this_plan_text: string | null
  is_active: boolean
  rates: Partial<Record<CommissionRateCategory, number>>
}

export type CommissionGuideCaller = {
  is_elevated: boolean
  is_self: boolean
}

export type CommissionGuideEnvelope = {
  as_of_date: string
  staff: CommissionGuideStaff
  plan: CommissionGuidePlan | null
  plan_summary: CommissionGuidePlanSummary
  rate_cards: CommissionGuideRateCard[]
  classification_table: CommissionGuideClassificationRow[]
  exclusions: CommissionGuideExclusion[]
  special_cases: CommissionGuideSpecialCase[]
  examples: CommissionGuideExample[]
  caller: CommissionGuideCaller
}

/** Friendly labels for category codes that appear anywhere on the page. */
export const COMMISSION_CATEGORY_LABELS: Record<string, string> = {
  service: 'Salon service',
  retail_product: 'Retail product',
  professional_product: 'Treatment / professional product',
  toner_with_other_service: 'Toner added to another service',
  extensions_product: 'Extension hair / product',
  extensions_service: 'Extension service / labour',
  no_commission_voucher: 'Voucher sale, no commission',
  no_commission_greenfee: 'Green fee, no commission',
  no_commission_redo: 'Redo / rework, no commission',
  no_commission_trainingproduct: 'Training item, no commission',
  no_commission_miscellaneousproduct: 'Miscellaneous item, no commission',
  no_commission_unclassified: 'Unclassified, no commission',
  expected_no_commission: 'Expected no commission',
  zero_value_commission_row: 'No payable commission on this row',
  hold_unexpected_issue: 'Needs review / not currently payable',
}

export function friendlyCategoryLabel(code: string | null | undefined): string {
  if (!code) return '—'
  return COMMISSION_CATEGORY_LABELS[code] ?? code
}
