-- My Sales: theoretical (potential) assistant commission contributor
-- breakdown.
--
-- Adds a second contributor JSON column to the My Sales RPC so the
-- Potential Assist. Comm. table cell can render assistant icons next
-- to the dollar amount in exactly the same way the Assistant Comm.
-- cell already does for actual assistant commission.
--
-- New RPC column
-- --------------
--   theoretical_assistant_commission_contributors jsonb
--     [
--       { "staff_member_id": uuid,
--         "display_name":    text,
--         "amount_ex_gst":   numeric },
--       ...
--     ]
--   * Aggregated from the same payroll line rows that feed
--     total_theoretical_assistant_commission_ex_gst (the
--     theoretical_assistant_commission_amt_ex_gst column added in
--     20260828123000), grouped by (paid stylist, pay_week_start,
--     assistant staff_work_id, display-name fallback) - same shape
--     as the existing assistant_commission_contributors aggregation
--     that drives the actual-side icons.
--   * Same alphabetical ordering by lower(display_name) so icons
--     render in a deterministic visual order regardless of payload
--     ordering.
--   * Filtered to rows where theoretical_assistant_commission_amt_ex_gst
--     > 0 so zero-eligibility lines are dropped from the breakdown
--     (mirrors the > 0 filter on the actual contributor CTE).
--   * Returns '[]'::jsonb (not NULL) when there are no contributors,
--     matching the existing assistant_commission_contributors
--     fallback so the frontend can iterate without a null check.
--
-- Existing behaviour preserved
-- ----------------------------
--   * Every existing returned column (staff_*, pay_week_*, all four
--     total_*_commission_ex_gst, effective_*, assistant_commission_contributors)
--     keeps its name, type and meaning. Existing My Sales chart /
--     table / line preview continue to work unchanged.
--   * Sourced from v_admin_payroll_lines_weekly (already exposes the
--     theoretical_assistant_commission_amt_ex_gst column from the
--     20260828123000 migration). No new view, no second calculation
--     path, no payroll-engine change.
--
-- Not touched
-- -----------
--   * v_commission_calculations_core / qa, v_admin_payroll_lines /
--     _weekly, v_admin_payroll_summary_weekly (Admin Sales summary),
--     Staff Trends, KPI RPCs, contractor invoice RPCs, role / pay
--     history triggers, voucher exclusion, product classification.
--   * Actual assistant attribution and assistant_commission_contributors.

DROP FUNCTION IF EXISTS public.get_my_sales_trend_weekly();

CREATE OR REPLACE FUNCTION public.get_my_sales_trend_weekly()
RETURNS TABLE (
  staff_member_id                                  uuid,
  staff_display_name                               text,
  staff_full_name                                  text,
  pay_week_start                                   date,
  pay_week_end                                     date,
  pay_date                                         date,
  effective_primary_role                           text,
  effective_remuneration_plan                      text,
  total_sales_ex_gst                               numeric,
  total_actual_commission_ex_gst                   numeric,
  total_theoretical_commission_ex_gst              numeric,
  total_assistant_commission_ex_gst                numeric,
  total_theoretical_assistant_commission_ex_gst    numeric,
  assistant_commission_contributors                jsonb,
  theoretical_assistant_commission_contributors    jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  WITH me AS (
    SELECT a.staff_member_id
    FROM public.staff_member_user_access a
    WHERE a.user_id = auth.uid()
      AND COALESCE(a.is_active, false) = true
      AND a.staff_member_id IS NOT NULL
    LIMIT 1
  ),
  weekly AS (
    -- One row per (staff, pay_week) combined across locations. Same
    -- voucher exclusion as v_admin_payroll_summary_weekly.total_sales_ex_gst.
    SELECT
      l.derived_staff_paid_id                AS staff_member_id,
      l.pay_week_start,
      MAX(l.pay_week_end)                    AS pay_week_end,
      MAX(l.pay_date)                        AS pay_date,
      MAX(l.derived_staff_paid_display_name) AS staff_display_name,
      MAX(l.derived_staff_paid_full_name)    AS staff_full_name,
      ROUND(SUM(
        CASE
          WHEN public.is_voucher_sale_row(
            l.raw_product_type, l.product_type_actual,
            l.product_type_short, l.commission_product_service
          ) THEN 0::numeric
          ELSE COALESCE(l.price_ex_gst, 0::numeric)
        END
      ), 2) AS total_sales_ex_gst,
      ROUND(SUM(COALESCE(l.actual_commission_amt_ex_gst,             0::numeric)), 2) AS total_actual_commission_ex_gst,
      ROUND(SUM(COALESCE(l.theoretical_commission_amt_ex_gst,        0::numeric)), 2) AS total_theoretical_commission_ex_gst,
      ROUND(SUM(COALESCE(l.assistant_commission_amt_ex_gst,          0::numeric)), 2) AS total_assistant_commission_ex_gst,
      ROUND(SUM(COALESCE(l.theoretical_assistant_commission_amt_ex_gst, 0::numeric)), 2)
        AS total_theoretical_assistant_commission_ex_gst
    FROM public.v_admin_payroll_lines_weekly l
    JOIN me ON me.staff_member_id = l.derived_staff_paid_id
    GROUP BY l.derived_staff_paid_id, l.pay_week_start
  ),
  contrib_actual AS (
    -- Actual assistant breakdown sourced from the same payroll line
    -- rows that contribute to total_assistant_commission_ex_gst.
    SELECT
      l.derived_staff_paid_id AS staff_member_id,
      l.pay_week_start,
      l.staff_work_id         AS assistant_staff_member_id,
      COALESCE(
        NULLIF(TRIM(l.work_display_name), ''),
        NULLIF(TRIM(l.work_full_name),    ''),
        '(Unknown assistant)'
      ) AS assistant_display_name,
      ROUND(SUM(COALESCE(l.assistant_commission_amt_ex_gst, 0::numeric)), 2)
        AS amount_ex_gst
    FROM public.v_admin_payroll_lines_weekly l
    JOIN me ON me.staff_member_id = l.derived_staff_paid_id
    WHERE COALESCE(l.assistant_commission_amt_ex_gst, 0::numeric) > 0::numeric
    GROUP BY
      l.derived_staff_paid_id,
      l.pay_week_start,
      l.staff_work_id,
      COALESCE(
        NULLIF(TRIM(l.work_display_name), ''),
        NULLIF(TRIM(l.work_full_name),    ''),
        '(Unknown assistant)'
      )
  ),
  contrib_actual_agg AS (
    SELECT
      c.staff_member_id,
      c.pay_week_start,
      jsonb_agg(
        jsonb_build_object(
          'staff_member_id', c.assistant_staff_member_id,
          'display_name',    c.assistant_display_name,
          'amount_ex_gst',   c.amount_ex_gst
        )
        ORDER BY lower(c.assistant_display_name), c.assistant_staff_member_id
      ) AS assistant_commission_contributors
    FROM contrib_actual c
    GROUP BY c.staff_member_id, c.pay_week_start
  ),
  contrib_theoretical AS (
    -- NEW: theoretical (potential) assistant breakdown sourced from the
    -- same payroll line rows that contribute to
    -- total_theoretical_assistant_commission_ex_gst. Same grouping
    -- key as the actual breakdown so the JSON shape is identical
    -- and the frontend can reuse the same contributor renderer.
    SELECT
      l.derived_staff_paid_id AS staff_member_id,
      l.pay_week_start,
      l.staff_work_id         AS assistant_staff_member_id,
      COALESCE(
        NULLIF(TRIM(l.work_display_name), ''),
        NULLIF(TRIM(l.work_full_name),    ''),
        '(Unknown assistant)'
      ) AS assistant_display_name,
      ROUND(SUM(COALESCE(l.theoretical_assistant_commission_amt_ex_gst, 0::numeric)), 2)
        AS amount_ex_gst
    FROM public.v_admin_payroll_lines_weekly l
    JOIN me ON me.staff_member_id = l.derived_staff_paid_id
    WHERE COALESCE(l.theoretical_assistant_commission_amt_ex_gst, 0::numeric) > 0::numeric
    GROUP BY
      l.derived_staff_paid_id,
      l.pay_week_start,
      l.staff_work_id,
      COALESCE(
        NULLIF(TRIM(l.work_display_name), ''),
        NULLIF(TRIM(l.work_full_name),    ''),
        '(Unknown assistant)'
      )
  ),
  contrib_theoretical_agg AS (
    SELECT
      c.staff_member_id,
      c.pay_week_start,
      jsonb_agg(
        jsonb_build_object(
          'staff_member_id', c.assistant_staff_member_id,
          'display_name',    c.assistant_display_name,
          'amount_ex_gst',   c.amount_ex_gst
        )
        ORDER BY lower(c.assistant_display_name), c.assistant_staff_member_id
      ) AS theoretical_assistant_commission_contributors
    FROM contrib_theoretical c
    GROUP BY c.staff_member_id, c.pay_week_start
  )
  SELECT
    w.staff_member_id,
    w.staff_display_name,
    w.staff_full_name,
    w.pay_week_start,
    w.pay_week_end,
    w.pay_date,
    COALESCE(eff.primary_role,      sm.primary_role)      AS effective_primary_role,
    COALESCE(eff.remuneration_plan, sm.remuneration_plan) AS effective_remuneration_plan,
    w.total_sales_ex_gst,
    w.total_actual_commission_ex_gst,
    w.total_theoretical_commission_ex_gst,
    w.total_assistant_commission_ex_gst,
    w.total_theoretical_assistant_commission_ex_gst,
    COALESCE(ca.assistant_commission_contributors,             '[]'::jsonb) AS assistant_commission_contributors,
    COALESCE(ct.theoretical_assistant_commission_contributors, '[]'::jsonb) AS theoretical_assistant_commission_contributors
  FROM weekly w
  LEFT JOIN public.staff_members sm ON sm.id = w.staff_member_id
  LEFT JOIN LATERAL public.staff_profile_at(w.staff_member_id, w.pay_week_start) eff ON true
  LEFT JOIN contrib_actual_agg ca
    ON ca.staff_member_id = w.staff_member_id
   AND ca.pay_week_start  = w.pay_week_start
  LEFT JOIN contrib_theoretical_agg ct
    ON ct.staff_member_id = w.staff_member_id
   AND ct.pay_week_start  = w.pay_week_start
  ORDER BY w.pay_week_start DESC;
$fn$;

ALTER FUNCTION public.get_my_sales_trend_weekly() OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.get_my_sales_trend_weekly() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_sales_trend_weekly() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_sales_trend_weekly() TO service_role;

COMMENT ON FUNCTION public.get_my_sales_trend_weekly() IS
  'My Sales (/app/my-sales) personal Staff Trends data. One row per pay week for the calling user''s mapped staff_member_id, combined across locations. Totals come from v_admin_payroll_lines_weekly (same source as Sales Summary / Staff Trends; voucher rows excluded from total_sales_ex_gst via public.is_voucher_sale_row). effective_primary_role / effective_remuneration_plan resolved at pay_week_start via public.staff_profile_at with COALESCE fallback to current staff_members. assistant_commission_contributors aggregates the actual assistant breakdown straight from the same payroll line rows that feed total_assistant_commission_ex_gst (no new calculation path). theoretical_assistant_commission_contributors aggregates the theoretical (potential) assistant breakdown from the same payroll line rows that feed total_theoretical_assistant_commission_ex_gst (theoretical_assistant_commission_amt_ex_gst > 0 filter, same grouping + ordering as the actual side; used by the Potential Assist. Comm. table cell to render contributor icons). total_theoretical_assistant_commission_ex_gst is a SUM of the line-level theoretical_assistant_commission_amt_ex_gst column added in 20260828123000 and is useful for wage stylists where actual_commission_rate (and therefore actual assistant commission) is null. Returns zero rows for callers without an active staff_members mapping.';


-- ===========================================================================
-- Validation (informational NOTICEs only).
-- ===========================================================================
DO $$
DECLARE
  v_has_col boolean;
BEGIN
  SELECT EXISTS (
    SELECT 1
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname = 'get_my_sales_trend_weekly'
      AND EXISTS (
        SELECT 1
        FROM unnest(p.proargnames, p.proallargtypes) AS a(argname, argtype)
        WHERE argname = 'theoretical_assistant_commission_contributors'
      )
  )
  INTO v_has_col;
  RAISE NOTICE
    '[20260828124000] get_my_sales_trend_weekly.theoretical_assistant_commission_contributors exists: %',
    v_has_col;
END
$$ LANGUAGE plpgsql;
