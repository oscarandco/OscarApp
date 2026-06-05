-- Hotfix: get_my_sales_trend_weekly was hitting the statement timeout in
-- production. Diagnosis:
--
--   * Migration 20260828124000 added a second contributor aggregation
--     CTE (theoretical_assistant_commission_contributors) on top of
--     the existing actual contributor CTE. The RPC therefore did THREE
--     separate scans of v_admin_payroll_lines_weekly (weekly totals,
--     actual contributors, theoretical contributors), each walking
--     the full view stack
--     v_admin_payroll_lines_weekly -> v_admin_payroll_lines ->
--     v_commission_calculations_qa -> v_commission_calculations_core ->
--     v_sales_transactions_powerbi_parity -> sales_transactions
--     plus several LATERAL joins for name resolution.
--   * The me-staff-id filter is applied via JOIN inside each CTE, but
--     there is no sale_date / pay_week guardrail, so every pass walks
--     the entire historical line set even though My Sales only
--     displays the last 52 pay weeks.
--
-- This migration applies the smallest safe change:
--
--   1. Drops theoretical_assistant_commission_contributors from the
--      RETURNS TABLE and removes the contrib_theoretical /
--      contrib_theoretical_agg CTEs. Potential Assist. Comm. keeps
--      its dollar amount (total_theoretical_assistant_commission_ex_gst),
--      it just no longer ships an assistant icon breakdown. The
--      front-end is updated in the same change to render amount-only.
--   2. Adds a `WHERE l.sale_date >= (current_date - INTERVAL '54 weeks')`
--      guardrail to both remaining CTEs (weekly and contrib_actual).
--      54 weeks (52 + 2 buffer) covers the 52-week window the page
--      shows plus any pay-week alignment slack.
--   3. Restores the exact previous shape of the actual-side aggregation
--      (no change to actual Assistant Comm. icons) because the
--      pre-20260828124000 form was performant in production.
--
-- Future option (not implemented here): expose theoretical assistant
-- contributors via a separate lazy RPC like
-- public.get_my_sales_assistant_commission_contributors(p_pay_week_start date)
-- that the page can call only when a Potential Assist. Comm. cell is
-- hovered or expanded. Cheaper because the contributor aggregation is
-- scoped to one week and one staff member. Out of scope for this hotfix.
--
-- Not touched
-- -----------
--   * Commission engine (v_commission_calculations_core etc.) and
--     all *_amt_ex_gst formulas - byte-identical.
--   * Admin Sales summary (v_admin_payroll_summary_weekly,
--     get_admin_payroll_summary_weekly) - unchanged.
--   * Staff Trends, KPI RPCs, contractor invoice RPCs, role/pay history.
--   * The line preview route /app/my-sales/YYYY-MM-DD and modal.

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
  assistant_commission_contributors                jsonb
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
    --
    -- Hard-bounded to the last 54 weeks of sale_date (52 visible + 2
    -- weeks alignment buffer). This is the main perf guardrail: with
    -- the underlying sales_transactions(sale_date) index it keeps the
    -- scan from walking historical data the page will never show.
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
    WHERE l.sale_date >= (current_date - INTERVAL '54 weeks')
    GROUP BY l.derived_staff_paid_id, l.pay_week_start
  ),
  contrib_actual AS (
    -- Actual assistant breakdown sourced from the same payroll line
    -- rows that contribute to total_assistant_commission_ex_gst.
    -- Restricted to the same 54-week window as weekly so this CTE
    -- can't outgrow the main pass.
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
    WHERE l.sale_date >= (current_date - INTERVAL '54 weeks')
      AND COALESCE(l.assistant_commission_amt_ex_gst, 0::numeric) > 0::numeric
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
    COALESCE(ca.assistant_commission_contributors, '[]'::jsonb) AS assistant_commission_contributors
  FROM weekly w
  LEFT JOIN public.staff_members sm ON sm.id = w.staff_member_id
  LEFT JOIN LATERAL public.staff_profile_at(w.staff_member_id, w.pay_week_start) eff ON true
  LEFT JOIN contrib_actual_agg ca
    ON ca.staff_member_id = w.staff_member_id
   AND ca.pay_week_start  = w.pay_week_start
  ORDER BY w.pay_week_start DESC;
$fn$;

ALTER FUNCTION public.get_my_sales_trend_weekly() OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.get_my_sales_trend_weekly() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_sales_trend_weekly() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_sales_trend_weekly() TO service_role;

COMMENT ON FUNCTION public.get_my_sales_trend_weekly() IS
  'My Sales (/app/my-sales) personal Staff Trends data: one row per pay week for the calling user''s mapped staff_member_id, combined across locations. Totals come from v_admin_payroll_lines_weekly (same source as Sales Summary / Staff Trends; voucher rows excluded from total_sales_ex_gst via public.is_voucher_sale_row). Bounded to sale_date >= current_date - 54 weeks as a perf guardrail (page only renders the last 52 pay weeks; 2 weeks buffer for alignment). effective_primary_role / effective_remuneration_plan resolved at pay_week_start via public.staff_profile_at with COALESCE fallback to current staff_members. assistant_commission_contributors aggregates the ACTUAL assistant breakdown from the same payroll line rows that feed total_assistant_commission_ex_gst (no new calculation path). total_theoretical_assistant_commission_ex_gst is a SUM of the line-level theoretical_assistant_commission_amt_ex_gst column added in 20260828123000. Theoretical (potential) assistant contributor breakdown was previously included as theoretical_assistant_commission_contributors but was removed in 20260828125000 because the extra contributor CTE pass caused the RPC to hit the statement timeout in production; if Potential Assist. Comm. icons are needed in future they should be served by a separate lazy single-week RPC. Returns zero rows for callers without an active staff_members mapping.';


-- ===========================================================================
-- Validation (informational NOTICEs only).
--   * The previous-turn theoretical contributors column should be gone.
--   * The actual contributors column should still be present.
--   * 54-week guardrail in place: only weeks within the last ~52 should
--     be returned for any callable mapped staff member.
-- ===========================================================================
DO $$
DECLARE
  v_has_actual      boolean;
  v_has_theoretical boolean;
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
        WHERE argname = 'assistant_commission_contributors'
      )
  )
  INTO v_has_actual;

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
  INTO v_has_theoretical;

  RAISE NOTICE
    '[20260828125000] get_my_sales_trend_weekly.assistant_commission_contributors exists: %',
    v_has_actual;
  RAISE NOTICE
    '[20260828125000] get_my_sales_trend_weekly.theoretical_assistant_commission_contributors exists (should be FALSE after hotfix): %',
    v_has_theoretical;
END
$$ LANGUAGE plpgsql;
