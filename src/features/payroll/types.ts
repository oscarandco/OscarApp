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
  derived_staff_paid_display_name?: string | null
  row_count?: number | string | null
  total_sales_ex_gst?: number | string | null
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
  pay_week_start?: string | null
  pay_week_end?: string | null
  pay_date?: string | null
  customer_name?: string | null
  product_service_name?: string | null
  quantity?: number | string | null
  price_ex_gst?: number | string | null
  derived_staff_paid_display_name?: string | null
  actual_commission_amount?: number | string | null
  assistant_commission_amount?: number | string | null
  payroll_status?: string | null
  stylist_visible_note?: string | null
  location_id?: string | null
  location_name?: string | null
  access_role?: string | null
  [key: string]: string | number | boolean | null | undefined
}
