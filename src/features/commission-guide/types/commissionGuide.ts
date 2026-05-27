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

/** One headed note rendered as a card under the plan summary. */
export type CommissionGuideNote = {
  heading: string
  body: string
}

/** Wage / contractor / commission / none — drives the plan-summary paragraph. */
export type CommissionGuidePlanStyle = 'wage' | 'contractor' | 'commission' | 'none'

export type CommissionGuidePlanSummary = {
  headline: string
  plain_english: string
  important_notes: CommissionGuideNote[]
  plan_style: CommissionGuidePlanStyle
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
  /** Null for narrative-only examples (e.g. "Voucher used later"). */
  sale_ex_gst: number | null
  rate: number | null
  /** Null when the example is narrative-only (the outcome depends on the actual sale). */
  commission: number | null
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

/**
 * Long-form labels for category codes (used in places that need the
 * "why no commission" context, e.g. internal admin views or tooltips).
 */
export const COMMISSION_CATEGORY_LABELS: Record<string, string> = {
  service: 'Salon service',
  retail_product: 'Retail product',
  professional_product: 'Treatment / professional product',
  toner_with_other_service: 'Toner added to another service',
  extensions_product: 'Extension hair / product',
  extensions_service: 'Extension labour',
  no_commission_voucher: 'Voucher sale, no commission',
  no_commission_greenfee: 'Green fee, no commission',
  no_commission_redo: 'Redo / rework, no commission',
  no_commission_trainingproduct: 'Training item, no commission',
  no_commission_miscellaneousproduct: 'Miscellaneous, no commission',
  no_commission_unclassified: 'Unclassified, no commission',
  expected_no_commission: 'Expected no commission',
  zero_value_commission_row: 'No payable commission on this row',
  hold_unexpected_issue: 'Needs review / not currently payable',
}

export function friendlyCategoryLabel(code: string | null | undefined): string {
  if (!code) return '—'
  return COMMISSION_CATEGORY_LABELS[code] ?? code
}

/**
 * Short, staff-facing label for the "How Oscar & Co treats it" column.
 * All `no_commission_*` codes collapse to a single user-friendly phrase
 * — the plain-English explanation column carries the "why".
 */
export function howWeTreatItLabel(
  code: CommissionCategoryAny | undefined,
): string {
  if (!code) return 'Not yet classified'
  switch (code) {
    case 'service':
      return 'Salon service'
    case 'retail_product':
      return 'Retail product'
    case 'professional_product':
      return 'Treatment / professional product'
    case 'toner_with_other_service':
      return 'Toner added to another service'
    case 'extensions_product':
      return 'Extension hair / product'
    case 'extensions_service':
      return 'Extension labour'
    default:
      if (code.startsWith('no_commission')) return 'No commission'
      return code
  }
}
