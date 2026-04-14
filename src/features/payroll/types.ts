/**
 * Rows from `get_my_commission_summary_weekly` — typically one row per pay week × location split.
 * Index signature allows additional scalar columns from the RPC without losing type safety on known fields.
 */
export interface WeeklyCommissionSummaryRow {
  user_id?: string | null
  pay_week_start?: string | null
  pay_week_end?: string | null
  pay_date?: string | null
  location_id?: string | null
  /** From `public.locations` join in RPC; prefer for display over `location_id`. */
  location_name?: string | null
  derived_staff_paid_id?: string | null
  derived_staff_paid_display_name?: string | null
  derived_staff_paid_full_name?: string | null
  derived_staff_paid_remuneration_plan?: string | null
  /** From `v_stylist_commission_summary_weekly_final` / `v_admin_payroll_summary_weekly`. */
  line_count?: number | string | null
  /** Legacy alias if ever returned; prefer `line_count`. */
  row_count?: number | string | null
  payable_line_count?: number | string | null
  expected_no_commission_line_count?: number | string | null
  zero_value_line_count?: number | string | null
  review_line_count?: number | string | null
  total_sales_ex_gst?: number | string | null
  total_actual_commission_ex_gst?: number | string | null
  total_theoretical_commission_ex_gst?: number | string | null
  total_assistant_commission_ex_gst?: number | string | null
  /** Legacy short names if present on older responses. */
  total_actual_commission?: number | string | null
  total_assistant_commission?: number | string | null
  unconfigured_paid_staff_line_count?: number | string | null
  has_unconfigured_paid_staff_rows?: boolean | null
  access_role?: string | null
  /** Extra scalar columns returned by the RPC (forward compatible). */
  [key: string]: string | number | boolean | null | undefined
}

/**
 * Rows from `get_my_commission_lines_weekly` — line-level commission detail.
 */
export interface WeeklyCommissionLineRow {
  user_id?: string | null
  id?: string | null
  invoice?: string | null
  sale_date?: string | null
  sale_datetime?: string | null
  pay_week_start?: string | null
  pay_week_end?: string | null
  pay_date?: string | null
  customer_name?: string | null
  product_service_name?: string | null
  quantity?: number | string | null
  price_ex_gst?: number | string | null
  derived_staff_paid_display_name?: string | null
  derived_staff_paid_full_name?: string | null
  derived_staff_paid_id?: string | null
  /** Prefer API field from `v_stylist_commission_lines_weekly_final`. */
  actual_commission_amt_ex_gst?: number | string | null
  actual_commission_amount?: number | string | null
  assistant_commission_amt_ex_gst?: number | string | null
  assistant_commission_amount?: number | string | null
  payroll_status?: string | null
  stylist_visible_note?: string | null
  location_id?: string | null
  location_name?: string | null
  access_role?: string | null
  [key: string]: string | number | boolean | null | undefined
}
