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
  /**
   * Distinct `work_display_name` values from line rows in this pay week ×
   * location × paid staff group (comma-separated), from
   * `v_admin_payroll_summary_weekly` via `v_stylist_commission_summary_weekly_final`.
   */
  work_performed_by?: string | null
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
 * Rows from `get_location_sales_summary_for_my_sales` — one row per
 * pay week × pay_date × location with **all-staff** `total_sales_ex_gst`
 * (same line basis as Sales Summary). Used only for My Sales KPI tiles.
 */
export interface LocationSalesSummaryKpiRow {
  pay_week_start?: string | null
  pay_week_end?: string | null
  pay_date?: string | null
  location_id?: string | null
  location_name?: string | null
  total_sales_ex_gst?: number | string | null
  [key: string]: string | number | boolean | null | undefined
}

/**
 * Rows from `get_sales_daily_sheets_data_sources` — one per active
 * SalesDailySheets `sales_import_batches` row (typically one per
 * salon location). Used by My Sales to render the "Data source N"
 * line and per-location sales tile labels.
 */
export interface SalesDailySheetsDataSourceRow {
  batch_id?: string | null
  location_id?: string | null
  location_code?: string | null
  location_name?: string | null
  source_file_name?: string | null
  row_count?: number | string | null
  first_sale_date?: string | null
  last_sale_date?: string | null
  imported_at?: string | null
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
  /** Work performer (from `v_admin_payroll_lines_weekly`); exposed on stylist lines after migration. */
  work_display_name?: string | null
  work_full_name?: string | null
  staff_work_name?: string | null
  staff_paid_name_derived?: string | null
  existing_staff_paid_name?: string | null
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
