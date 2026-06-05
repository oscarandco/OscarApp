-- My Sales: personal Staff Trends style RPC.
--
-- Adds a read-only RPC for the My Sales page (/app/my-sales). Returns one
-- row per pay week for the calling user's mapped staff_member_id, with
--   * the standard weekly totals (sales / actual comm / theoretical comm /
--     assistant comm) sourced from v_admin_payroll_lines_weekly so they
--     match Staff Trends and Sales Summary line-for-line,
--   * the staff member's effective primary_role / remuneration_plan at
--     pay_week_start via public.staff_profile_at(...), so historical pay
--     weeks reflect the role/plan in force at the time (Assistant/Wage
--     before a promotion, Stylist/Commission after, etc.), and
--   * the assistant_commission_contributors breakdown (assistant staff
--     member id, display name, amount ex GST) needed to render the
--     assistant icons in the Assistant Comm. column. Contributors are
--     aggregated from the same payroll line rows that drive the
--     assistant_commission_amt_ex_gst totals, no new calculation
--     pipeline.
--
-- Important invariants
-- --------------------
--   * No payroll engine logic, commission calculations, assistant
--     attribution, KPI RPC, contractor invoice RPC, or role/pay history
--     trigger is touched. This migration only ADDs a SECURITY DEFINER
--     read RPC backed by existing trusted views.
--   * Locations are combined per pay week (one row per pay week per
--     staff member) so the My Sales chart aligns with Staff Trends
--     individual charts (which also combine across locations).
--   * Voucher rows are excluded from total_sales_ex_gst using the same
--     public.is_voucher_sale_row(...) helper as v_admin_payroll_summary_weekly
--     so the My Sales chart matches Sales Summary / Staff Trends.
--   * The caller is restricted to their own mapped staff_member_id via
--     staff_member_user_access (active, mapped). Admin/manager callers
--     who are not mapped to a staff_members row get zero rows back; they
--     should keep using Admin > Sales summary / Staff trends for the
--     all-staff view.

CREATE OR REPLACE FUNCTION public.get_my_sales_trend_weekly()
RETURNS TABLE (
  staff_member_id                       uuid,
  staff_display_name                    text,
  staff_full_name                       text,
  pay_week_start                        date,
  pay_week_end                          date,
  pay_date                              date,
  effective_primary_role                text,
  effective_remuneration_plan           text,
  total_sales_ex_gst                    numeric,
  total_actual_commission_ex_gst        numeric,
  total_theoretical_commission_ex_gst   numeric,
  total_assistant_commission_ex_gst     numeric,
  assistant_commission_contributors     jsonb
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
      l.derived_staff_paid_id AS staff_member_id,
      l.pay_week_start,
      MAX(l.pay_week_end)                          AS pay_week_end,
      MAX(l.pay_date)                              AS pay_date,
      MAX(l.derived_staff_paid_display_name)       AS staff_display_name,
      MAX(l.derived_staff_paid_full_name)          AS staff_full_name,
      ROUND(SUM(
        CASE
          WHEN public.is_voucher_sale_row(
            l.raw_product_type, l.product_type_actual,
            l.product_type_short, l.commission_product_service
          ) THEN 0::numeric
          ELSE COALESCE(l.price_ex_gst, 0::numeric)
        END
      ), 2)                                        AS total_sales_ex_gst,
      ROUND(SUM(COALESCE(l.actual_commission_amt_ex_gst,      0::numeric)), 2) AS total_actual_commission_ex_gst,
      ROUND(SUM(COALESCE(l.theoretical_commission_amt_ex_gst, 0::numeric)), 2) AS total_theoretical_commission_ex_gst,
      ROUND(SUM(COALESCE(l.assistant_commission_amt_ex_gst,   0::numeric)), 2) AS total_assistant_commission_ex_gst
    FROM public.v_admin_payroll_lines_weekly l
    JOIN me ON me.staff_member_id = l.derived_staff_paid_id
    GROUP BY l.derived_staff_paid_id, l.pay_week_start
  ),
  contrib AS (
    -- Assistant breakdown sourced from the same payroll line rows that
    -- contribute to total_assistant_commission_ex_gst. Grouped by
    -- (paid stylist, pay_week, assistant staff_work_id, assistant
    -- display name fallback) so the JSON shape mirrors the spec:
    --   [{ staff_member_id, display_name, amount_ex_gst }, ...]
    SELECT
      l.derived_staff_paid_id AS staff_member_id,
      l.pay_week_start,
      l.staff_work_id         AS assistant_staff_member_id,
      COALESCE(
        NULLIF(TRIM(l.work_display_name), ''),
        NULLIF(TRIM(l.work_full_name),    ''),
        '(Unknown assistant)'
      )                       AS assistant_display_name,
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
  contrib_agg AS (
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
    FROM contrib c
    GROUP BY c.staff_member_id, c.pay_week_start
  )
  SELECT
    w.staff_member_id,
    w.staff_display_name,
    w.staff_full_name,
    w.pay_week_start,
    w.pay_week_end,
    w.pay_date,
    -- Effective-dated role / plan at pay_week_start. COALESCE fallback
    -- to current staff_members keeps behaviour stable for any staff
    -- pre-dating the role-assignment history backfill.
    COALESCE(eff.primary_role,      sm.primary_role)      AS effective_primary_role,
    COALESCE(eff.remuneration_plan, sm.remuneration_plan) AS effective_remuneration_plan,
    w.total_sales_ex_gst,
    w.total_actual_commission_ex_gst,
    w.total_theoretical_commission_ex_gst,
    w.total_assistant_commission_ex_gst,
    COALESCE(ca.assistant_commission_contributors, '[]'::jsonb) AS assistant_commission_contributors
  FROM weekly w
  LEFT JOIN public.staff_members sm ON sm.id = w.staff_member_id
  LEFT JOIN LATERAL public.staff_profile_at(w.staff_member_id, w.pay_week_start) eff ON true
  LEFT JOIN contrib_agg ca
    ON ca.staff_member_id = w.staff_member_id
   AND ca.pay_week_start  = w.pay_week_start
  ORDER BY w.pay_week_start DESC;
$fn$;

ALTER FUNCTION public.get_my_sales_trend_weekly() OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.get_my_sales_trend_weekly() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_sales_trend_weekly() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_sales_trend_weekly() TO service_role;

COMMENT ON FUNCTION public.get_my_sales_trend_weekly() IS
  'My Sales (/app/my-sales) personal Staff Trends data: one row per pay week for the calling user''s mapped staff_member_id, combined across locations. Totals come from v_admin_payroll_lines_weekly (same source as Sales Summary / Staff Trends; voucher rows excluded from total_sales_ex_gst via public.is_voucher_sale_row). effective_primary_role / effective_remuneration_plan resolved at pay_week_start via public.staff_profile_at with COALESCE fallback to current staff_members. assistant_commission_contributors aggregates the assistant breakdown straight from the same payroll line rows that feed total_assistant_commission_ex_gst (no new calculation path). Returns zero rows for callers without an active staff_members mapping.';
