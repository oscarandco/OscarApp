-- Paid staff primary location on admin payroll line/summary views (for Weekly
-- Payroll badges). Sale/import location_id + location_name unchanged.

CREATE OR REPLACE VIEW public.v_admin_payroll_lines_weekly AS
SELECT
  l.*,
  (
    (l.sale_date
      - ((((EXTRACT(isodow FROM l.sale_date))::integer - 1))::double precision
        * '1 day'::interval))
  )::date AS pay_week_start,
  (
    (l.sale_date
      - ((((EXTRACT(isodow FROM l.sale_date))::integer - 1))::double precision
        * '1 day'::interval))
    + '6 days'::interval
  )::date AS pay_week_end,
  (
    (l.sale_date
      - ((((EXTRACT(isodow FROM l.sale_date))::integer - 1))::double precision
        * '1 day'::interval))
    + '10 days'::interval
  )::date AS pay_date,
  loc.name AS location_name,
  sm_paid.primary_location_id AS derived_staff_paid_primary_location_id,
  paid_loc.code AS derived_staff_paid_primary_location_code,
  paid_loc.name AS derived_staff_paid_primary_location_name
FROM public.v_admin_payroll_lines AS l
LEFT JOIN public.locations AS loc ON loc.id = l.location_id
LEFT JOIN public.staff_members AS sm_paid ON sm_paid.id = l.derived_staff_paid_id
LEFT JOIN public.locations AS paid_loc ON paid_loc.id = sm_paid.primary_location_id;

ALTER VIEW public.v_admin_payroll_lines_weekly OWNER TO postgres;

COMMENT ON VIEW public.v_admin_payroll_lines_weekly IS
  'Admin payroll lines with pay week + sale location; adds paid staff primary location from staff_members.primary_location_id for reporting badges.';

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
  count(*) FILTER (WHERE payroll_status = 'payable'::text) AS payable_line_count,
  count(*) FILTER (WHERE payroll_status = 'expected_no_commission'::text) AS expected_no_commission_line_count,
  count(*) FILTER (WHERE payroll_status = 'zero_value_commission_row'::text) AS zero_value_line_count,
  count(*) FILTER (WHERE requires_review = true) AS review_line_count,
  round(sum(coalesce(price_ex_gst, (0)::numeric)), 2) AS total_sales_ex_gst,
  round(sum(coalesce(actual_commission_amt_ex_gst, (0)::numeric)), 2) AS total_actual_commission_ex_gst,
  round(sum(coalesce(theoretical_commission_amt_ex_gst, (0)::numeric)), 2) AS total_theoretical_commission_ex_gst,
  round(sum(coalesce(assistant_commission_amt_ex_gst, (0)::numeric)), 2) AS total_assistant_commission_ex_gst,
  count(*) FILTER (WHERE calculation_alert = 'non_commission_unconfigured_paid_staff'::text) AS unconfigured_paid_staff_line_count,
  coalesce(bool_or(calculation_alert = 'non_commission_unconfigured_paid_staff'::text), false) AS has_unconfigured_paid_staff_rows,
  location_name,
  string_agg(DISTINCT NULLIF(TRIM(work_display_name), ''), ', ') AS work_performed_by,
  derived_staff_paid_primary_location_id,
  derived_staff_paid_primary_location_code,
  derived_staff_paid_primary_location_name
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
  location_name,
  derived_staff_paid_primary_location_id,
  derived_staff_paid_primary_location_code,
  derived_staff_paid_primary_location_name;

ALTER VIEW public.v_admin_payroll_summary_weekly OWNER TO postgres;

COMMENT ON VIEW public.v_admin_payroll_summary_weekly IS
  'Aggregated admin payroll summary per week/location/staff; includes paid staff primary location fields for UI badges.';
