import type {
  WeeklyCommissionLineRow,
  WeeklyCommissionSummaryRow,
} from '@/features/payroll/types'

/**
 * `get_admin_payroll_summary_weekly` — same measures as stylist summary; may scope by staff/location.
 */
export interface AdminPayrollSummaryRow extends WeeklyCommissionSummaryRow {
  staff_member_id?: string | null
  staff_full_name?: string | null
  derived_staff_paid_primary_location_id?: string | null
  derived_staff_paid_primary_location_code?: string | null
  derived_staff_paid_primary_location_name?: string | null
}

/**
 * `get_admin_payroll_lines_weekly` — line-level; optional admin-only audit fields.
 */
export interface AdminPayrollLineRow extends WeeklyCommissionLineRow {
  internal_note?: string | null
  /** From `v_admin_payroll_lines_weekly` / commission QA pipeline. */
  commission_category_final?: string | null
  /** From `v_admin_payroll_lines_weekly` (e.g. Comm - Products / Comm - Services). */
  commission_product_service?: string | null
  derived_staff_paid_primary_location_id?: string | null
  derived_staff_paid_primary_location_code?: string | null
  derived_staff_paid_primary_location_name?: string | null
}
