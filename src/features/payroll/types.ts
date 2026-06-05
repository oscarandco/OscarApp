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
 * Rows from `get_sales_daily_sheets_data_sources_by_location` — one per salon
 * (`location_id`), aggregating current SalesDailySheets-backed
 * `sales_transactions` (counts and sale_date range). Drives the
 * "Data - {Location}" toolbar lines and per-location sales tile labels.
 */
export interface SalesDailySheetsDataSourceRow {
  location_id?: string | null
  location_code?: string | null
  location_name?: string | null
  row_count?: number | string | null
  min_sale_date?: string | null
  max_sale_date?: string | null
}

/**
 * One assistant's contribution to a stylist's weekly assistant commission,
 * as returned by `get_my_sales_trend_weekly.assistant_commission_contributors`.
 * Sourced from the same payroll line rows that feed
 * `total_assistant_commission_ex_gst`; no separate calculation path.
 */
export interface AssistantCommissionContributor {
  /** Assistant `staff_members.id`; may be null if the work staff was name-only. */
  staff_member_id?: string | null
  display_name?: string | null
  amount_ex_gst?: number | string | null
}

/**
 * Rows from `get_my_sales_trend_weekly`: one row per pay week for the
 * logged-in user's mapped staff member, combined across locations. Drives
 * the My Sales (/app/my-sales) personal Staff Trends chart and weekly
 * breakdown table. Same total basis as `v_admin_payroll_summary_weekly`
 * (Staff Trends / Sales Summary).
 */
export interface MySalesTrendWeeklyRow {
  staff_member_id?: string | null
  staff_display_name?: string | null
  staff_full_name?: string | null
  pay_week_start?: string | null
  pay_week_end?: string | null
  pay_date?: string | null
  /** Effective primary_role at `pay_week_start` (staff_profile_at), with current-row fallback. */
  effective_primary_role?: string | null
  /** Effective remuneration plan at `pay_week_start` (staff_profile_at), with current-row fallback. */
  effective_remuneration_plan?: string | null
  total_sales_ex_gst?: number | string | null
  total_actual_commission_ex_gst?: number | string | null
  total_theoretical_commission_ex_gst?: number | string | null
  total_assistant_commission_ex_gst?: number | string | null
  /**
   * Potential / theoretical assistant commission: the assistant
   * commission amount that would have applied to assistant work for
   * this stylist if their plan was the benchmark Commission plan.
   * Useful for wage stylists where actual_commission_rate (and
   * therefore the actual assistant commission column) is usually $0.00.
   *
   * Sourced from the line-level
   * `theoretical_assistant_commission_amt_ex_gst` column added in the
   * 20260828123000 migration; the RPC just ROUND(SUM(...))s it. No new
   * commission calculation path.
   */
  total_theoretical_assistant_commission_ex_gst?: number | string | null
  /** Empty array when no contributor breakdown is available for the week. */
  assistant_commission_contributors?: AssistantCommissionContributor[] | null
  [key: string]: unknown
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
  /**
   * `product_type_short_derived` from commission core; `v_admin_payroll_lines`
   * often exposes it as `product_type_short`. Used for Weekly Payroll vs summary buckets.
   */
  product_type_short_derived?: string | null
  product_type_short?: string | null
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
  /** Admin payroll: unique staff_members match when `derived_staff_paid_id` is null (`v_admin_payroll_lines_weekly`). */
  resolved_derived_staff_paid_id?: string | null
  resolved_derived_staff_paid_display_name?: string | null
  resolved_derived_staff_paid_full_name?: string | null
  resolved_derived_staff_paid_remuneration_plan?: string | null
  resolved_derived_staff_paid_primary_location_id?: string | null
  resolved_derived_staff_paid_primary_location_code?: string | null
  resolved_derived_staff_paid_primary_location_name?: string | null
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
