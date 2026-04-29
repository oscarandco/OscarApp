-- Distinct work_display_name values per summary group (Sales Summary "Work performed by" column).

CREATE OR REPLACE VIEW public.v_admin_payroll_summary_weekly AS
SELECT
  pay_week_start,
  pay_week_end,
  pay_date,
  location_id,
  derived_staff_paid_id,
  derived_staff_paid_display_name,
  derived_staff_paid_full_name,
  derived_staff_paid_remuneration_plan,
  count(*) AS line_count,
  count(*) FILTER (WHERE (payroll_status = 'payable'::text)) AS payable_line_count,
  count(*) FILTER (WHERE (payroll_status = 'expected_no_commission'::text)) AS expected_no_commission_line_count,
  count(*) FILTER (WHERE (payroll_status = 'zero_value_commission_row'::text)) AS zero_value_line_count,
  count(*) FILTER (WHERE (requires_review = true)) AS review_line_count,
  round(sum(coalesce(price_ex_gst, (0)::numeric)), 2) AS total_sales_ex_gst,
  round(sum(coalesce(actual_commission_amt_ex_gst, (0)::numeric)), 2) AS total_actual_commission_ex_gst,
  round(sum(coalesce(theoretical_commission_amt_ex_gst, (0)::numeric)), 2) AS total_theoretical_commission_ex_gst,
  round(sum(coalesce(assistant_commission_amt_ex_gst, (0)::numeric)), 2) AS total_assistant_commission_ex_gst,
  count(*) FILTER (WHERE (calculation_alert = 'non_commission_unconfigured_paid_staff'::text)) AS unconfigured_paid_staff_line_count,
  coalesce(bool_or((calculation_alert = 'non_commission_unconfigured_paid_staff'::text)), false) AS has_unconfigured_paid_staff_rows,
  location_name,
  string_agg(DISTINCT NULLIF(TRIM(work_display_name), ''), ', ') AS work_performed_by
FROM public.v_admin_payroll_lines_weekly
GROUP BY
  pay_week_start,
  pay_week_end,
  pay_date,
  location_id,
  derived_staff_paid_id,
  derived_staff_paid_display_name,
  derived_staff_paid_full_name,
  derived_staff_paid_remuneration_plan,
  location_name;
