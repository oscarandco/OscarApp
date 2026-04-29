-- Canonical paid staff identity for admin payroll reporting: resolve name-only
-- fallbacks to staff_members when the match is unique (display_name or full_name,
-- case-insensitive, trimmed). Existing derived_* columns unchanged. New resolved_*
-- columns appended only. Summary groups by resolved identity; output staff columns
-- remain named derived_staff_paid_* for RPC compatibility.

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
  paid_loc.name AS derived_staff_paid_primary_location_name,
  res_staff.final_staff_id AS resolved_derived_staff_paid_id,
  COALESCE(sm_res.display_name, l.derived_staff_paid_display_name) AS resolved_derived_staff_paid_display_name,
  COALESCE(sm_res.full_name, l.derived_staff_paid_full_name) AS resolved_derived_staff_paid_full_name,
  COALESCE(sm_res.remuneration_plan, l.derived_staff_paid_remuneration_plan) AS resolved_derived_staff_paid_remuneration_plan,
  sm_res.primary_location_id AS resolved_derived_staff_paid_primary_location_id,
  paid_loc_res.code AS resolved_derived_staff_paid_primary_location_code,
  paid_loc_res.name AS resolved_derived_staff_paid_primary_location_name
FROM public.v_admin_payroll_lines AS l
LEFT JOIN public.locations AS loc ON loc.id = l.location_id
LEFT JOIN public.staff_members AS sm_paid ON sm_paid.id = l.derived_staff_paid_id
LEFT JOIN public.locations AS paid_loc ON paid_loc.id = sm_paid.primary_location_id
LEFT JOIN LATERAL (
  SELECT
    NULLIF(
      trim(lower(coalesce(l.derived_staff_paid_display_name, l.staff_paid_name_derived, ''))),
      ''
    ) AS cand_dn,
    NULLIF(trim(lower(coalesce(l.derived_staff_paid_full_name, ''))), '') AS cand_fn
) AS nm ON true
LEFT JOIN LATERAL (
  SELECT
    CASE
      WHEN l.derived_staff_paid_id IS NOT NULL THEN l.derived_staff_paid_id
      WHEN nm.cand_dn IS NOT NULL
        AND (
          SELECT count(*)::integer
          FROM public.staff_members sm
          WHERE lower(trim(sm.display_name)) = nm.cand_dn
        ) = 1
        THEN (
          SELECT sm.id
          FROM public.staff_members sm
          WHERE lower(trim(sm.display_name)) = nm.cand_dn
          LIMIT 1
        )
      WHEN nm.cand_dn IS NOT NULL
        AND (
          SELECT count(*)::integer
          FROM public.staff_members sm
          WHERE lower(trim(sm.full_name)) = nm.cand_dn
        ) = 1
        THEN (
          SELECT sm.id
          FROM public.staff_members sm
          WHERE lower(trim(sm.full_name)) = nm.cand_dn
          LIMIT 1
        )
      WHEN nm.cand_fn IS NOT NULL
        AND nm.cand_fn IS DISTINCT FROM nm.cand_dn
        AND (
          SELECT count(*)::integer
          FROM public.staff_members sm
          WHERE lower(trim(sm.full_name)) = nm.cand_fn
        ) = 1
        THEN (
          SELECT sm.id
          FROM public.staff_members sm
          WHERE lower(trim(sm.full_name)) = nm.cand_fn
          LIMIT 1
        )
      WHEN nm.cand_fn IS NOT NULL
        AND nm.cand_fn IS DISTINCT FROM nm.cand_dn
        AND (
          SELECT count(*)::integer
          FROM public.staff_members sm
          WHERE lower(trim(sm.display_name)) = nm.cand_fn
        ) = 1
        THEN (
          SELECT sm.id
          FROM public.staff_members sm
          WHERE lower(trim(sm.display_name)) = nm.cand_fn
          LIMIT 1
        )
      ELSE NULL
    END AS final_staff_id
) AS res_staff ON true
LEFT JOIN public.staff_members AS sm_res ON sm_res.id = res_staff.final_staff_id
LEFT JOIN public.locations AS paid_loc_res ON paid_loc_res.id = sm_res.primary_location_id;

ALTER VIEW public.v_admin_payroll_lines_weekly OWNER TO postgres;

COMMENT ON VIEW public.v_admin_payroll_lines_weekly IS
  'Admin payroll lines with pay week, sale location, derived paid-staff primary location, '
  'and resolved paid-staff identity (unique staff_members match on display/full name when derived_staff_paid_id is null).';

CREATE OR REPLACE VIEW public.v_admin_payroll_summary_weekly AS
SELECT
  pay_week_start,
  pay_week_end,
  pay_date,
  location_id,
  resolved_derived_staff_paid_id AS derived_staff_paid_id,
  resolved_derived_staff_paid_display_name AS derived_staff_paid_display_name,
  resolved_derived_staff_paid_full_name AS derived_staff_paid_full_name,
  resolved_derived_staff_paid_remuneration_plan AS derived_staff_paid_remuneration_plan,
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
  resolved_derived_staff_paid_primary_location_id AS derived_staff_paid_primary_location_id,
  resolved_derived_staff_paid_primary_location_code AS derived_staff_paid_primary_location_code,
  resolved_derived_staff_paid_primary_location_name AS derived_staff_paid_primary_location_name
FROM public.v_admin_payroll_lines_weekly
GROUP BY
  pay_week_start,
  pay_week_end,
  pay_date,
  location_id,
  resolved_derived_staff_paid_id,
  resolved_derived_staff_paid_display_name,
  resolved_derived_staff_paid_full_name,
  resolved_derived_staff_paid_remuneration_plan,
  location_name,
  resolved_derived_staff_paid_primary_location_id,
  resolved_derived_staff_paid_primary_location_code,
  resolved_derived_staff_paid_primary_location_name;

ALTER VIEW public.v_admin_payroll_summary_weekly OWNER TO postgres;

COMMENT ON VIEW public.v_admin_payroll_summary_weekly IS
  'Aggregated admin payroll per week/location/staff; staff key is resolved identity '
  '(derived_staff_paid_* columns expose canonical values for API compatibility).';
