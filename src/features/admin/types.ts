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
}

/**
 * `get_admin_payroll_lines_weekly` — line-level; optional admin-only audit fields.
 */
export interface AdminPayrollLineRow extends WeeklyCommissionLineRow {
  internal_note?: string | null
}
