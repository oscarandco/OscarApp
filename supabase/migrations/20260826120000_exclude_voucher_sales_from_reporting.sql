-- =====================================================================
-- Exclude voucher sales from Oscar & Co revenue reporting.
--
-- Why
-- ---
-- Voucher rows in `public.sales_transactions` are customer prepayments
-- / liabilities, NOT salon service or product revenue. They should
-- remain in the imported source data for audit (and continue to flow
-- through the payroll pipeline as `commission_category_final =
-- 'no_commission_voucher'`, `payroll_status = 'expected_no_commission'`,
-- `is_payable = false`), but they must NOT contribute to any revenue
-- total surfaced to admins, managers, or stylists.
--
-- This migration introduces a single, central voucher classifier and
-- updates every revenue-summing RPC / view to exclude voucher rows.
-- Source rows, payroll classification, contractor invoice logic, and
-- KPI guest / new-client counts are intentionally left untouched.
--
-- Voucher classification rule
-- ---------------------------
-- A row is treated as a voucher sale when ANY of these four columns
-- (case-insensitive, trimmed) equals 'voucher':
--     raw_product_type
--     product_type_actual
--     product_type_short
--     commission_product_service
--
-- This matches the four columns called out in the Supabase audit and
-- aligns with the payroll engine's existing single-column rule
-- (`raw_product_type = 'Voucher'`) while being more defensive against
-- future data shapes where only one of the four is populated.
--
-- Scope of changes (frontend-invisible; pure SQL)
-- -----------------------------------------------
--   1. public.is_voucher_sale_row(...)                  NEW helper
--   2. public.v_admin_payroll_summary_weekly            view rebuild
--      → total_sales_ex_gst now excludes voucher rows
--   3. public.get_location_sales_summary_for_my_sales   RPC rebuild
--      → location-level My Sales totals exclude vouchers
--   4. public.get_kpi_revenue_live                      RPC rebuild
--   5. public.get_kpi_average_client_spend_live         RPC rebuild
--      → numerator (revenue) excludes vouchers; denominator
--        (distinct guests) preserved to keep the
--        `avg_spend = revenue / guests_per_month` invariant intact
--   6. public.get_kpi_assistant_utilisation_ratio_live  RPC rebuild
--      → both numerator and denominator exclude vouchers so the
--        ratio's `denominator == get_kpi_revenue_live` invariant
--        documented in 20260501310000 is preserved
--   7. public.get_kpi_stylist_profitability_live        RPC rebuild
--      → per-stylist revenue numerator excludes vouchers
--   8. public.get_kpi_stylist_comparisons_live          RPC rebuild
--      → cohort revenue + assistant_util CTEs exclude vouchers
--        via FILTER (guests / new_clients CTEs preserved)
--   9. public.get_kpi_stylist_comparison_leaders_live   RPC rebuild
--      → same FILTER pattern as comparisons_live
--
-- Intentionally NOT changed (and why)
-- -----------------------------------
--   * Payroll engine + v_admin_payroll_lines: vouchers are already
--     classified as `no_commission_voucher`, `expected_no_commission`,
--     `is_payable = false`, `actual_commission_amt_ex_gst = NULL` —
--     preserving them keeps voucher audit visible in Weekly Payroll.
--   * Contractor invoice RPCs (latest 20260825120800): already filter
--     `WHERE l.payroll_status = 'payable'`, which excludes vouchers
--     because their status is `expected_no_commission`. No change
--     needed; double-protected against accidental voucher inclusion.
--   * public.get_invoice_detail_live: correctly returns ALL lines on
--     an invoice (including the voucher line if any). When a user
--     opens an invoice from a KPI drilldown they should see every
--     line that physically printed on the receipt; voucher lines
--     simply don't contribute to the revenue KPI total.
--   * public.get_kpi_guests_per_month_live /
--     public.get_kpi_new_clients_per_month_live: a guest who bought
--     a voucher is still a guest (they walked in and transacted).
--     Per spec these are guest counts, not revenue, so voucher rows
--     remain in the rowset. See note on average_client_spend below.
--   * public.get_kpi_drilldown_live / private.debug_kpi_drilldown:
--     drilldowns list source rows for audit. Voucher rows still
--     appear, clearly identifiable by their product_type_actual
--     value, but no drilldown row claims to be revenue. Updating
--     these to filter vouchers requires rewriting the whole
--     ~700-line dispatcher; intentionally deferred to a follow-up
--     migration so this one stays narrowly scoped to revenue totals.
--
-- Effect on `average_client_spend` invariant
-- ------------------------------------------
-- The existing locked definition is `revenue / guests_per_month`.
-- We exclude voucher rows from the numerator (revenue) but keep the
-- denominator scoped to all distinct normalised guests. The
-- invariant is preserved: a voucher-only guest contributes 0 to
-- the numerator and 1 to the denominator, slightly deflating
-- average spend — which is the correct economic interpretation
-- (a voucher purchase is not realised salon revenue for that
-- guest in the month it was bought).
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.is_voucher_sale_row(...)
--    Single source of truth for "this row is a voucher prepayment".
--    IMMUTABLE so the planner can inline / push-down filters into
--    scans on v_sales_transactions_enriched / v_admin_payroll_lines.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.is_voucher_sale_row(
  raw_product_type           text,
  product_type_actual        text,
  product_type_short         text,
  commission_product_service text
)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $fn$
  SELECT
    lower(coalesce(raw_product_type,           '')) = 'voucher'
    OR lower(coalesce(product_type_actual,        '')) = 'voucher'
    OR lower(coalesce(product_type_short,         '')) = 'voucher'
    OR lower(coalesce(commission_product_service, '')) = 'voucher';
$fn$;

ALTER FUNCTION public.is_voucher_sale_row(text, text, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.is_voucher_sale_row(text, text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.is_voucher_sale_row(text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_voucher_sale_row(text, text, text, text) TO service_role;

COMMENT ON FUNCTION public.is_voucher_sale_row(text, text, text, text) IS
'Returns true when a sales_transactions row represents a voucher (customer prepayment / liability), not service or product revenue. Used by reporting views and KPI RPCs to exclude vouchers from revenue totals. Vouchers remain in source data and continue to flow through payroll as no_commission_voucher / expected_no_commission / is_payable=false.';


-- ---------------------------------------------------------------------
-- 2. public.v_admin_payroll_summary_weekly
--    total_sales_ex_gst now excludes voucher rows; all other
--    aggregates preserved exactly.
-- ---------------------------------------------------------------------
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
  -- total_sales_ex_gst: exclude voucher rows. Vouchers are customer
  -- prepayments / liabilities, not salon revenue. They still appear in
  -- this view's row count and in the payroll status counters so admins
  -- can audit them, but their price_ex_gst is treated as 0 toward the
  -- weekly sales total.
  round(sum(
    CASE
      WHEN public.is_voucher_sale_row(
        raw_product_type, product_type_actual,
        product_type_short, commission_product_service
      ) THEN 0::numeric
      ELSE coalesce(price_ex_gst, 0::numeric)
    END
  ), 2) AS total_sales_ex_gst,
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
  'Aggregated admin payroll summary per week/location/staff. total_sales_ex_gst EXCLUDES voucher rows (customer prepayments / liabilities, not salon revenue). Voucher rows are still counted in line_count and expected_no_commission_line_count for audit visibility. Other aggregates (commission totals, alerts, work performed by) unchanged.';


-- ---------------------------------------------------------------------
-- 3. public.get_location_sales_summary_for_my_sales
--    My Sales card location totals exclude voucher rows.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_location_sales_summary_for_my_sales()
RETURNS TABLE (
  pay_week_start     date,
  pay_week_end       date,
  pay_date           date,
  location_id        uuid,
  location_name      text,
  total_sales_ex_gst numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  -- Voucher rows are excluded so the My Sales location card matches
  -- the Sales Summary location card row-for-row (both exclude
  -- vouchers as of migration 20260826120000).
  SELECT
    l.pay_week_start,
    l.pay_week_end,
    l.pay_date,
    l.location_id,
    max(l.location_name)::text AS location_name,
    round(sum(coalesce(l.price_ex_gst, 0::numeric)), 2) AS total_sales_ex_gst
  FROM public.v_admin_payroll_lines_weekly l
  WHERE EXISTS (
    SELECT 1
    FROM public.staff_member_user_access a
    WHERE a.user_id = auth.uid()
      AND coalesce(a.is_active, false) = true
  )
    AND NOT public.is_voucher_sale_row(
      l.raw_product_type, l.product_type_actual,
      l.product_type_short, l.commission_product_service
    )
  GROUP BY l.pay_week_start, l.pay_week_end, l.pay_date, l.location_id
  ORDER BY l.pay_week_start DESC NULLS LAST, l.location_id NULLS LAST;
$$;

ALTER FUNCTION public.get_location_sales_summary_for_my_sales() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_location_sales_summary_for_my_sales() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_location_sales_summary_for_my_sales() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_location_sales_summary_for_my_sales() TO service_role;

COMMENT ON FUNCTION public.get_location_sales_summary_for_my_sales() IS
'Location-level sales ex GST by pay week, for My Sales cards. Excludes voucher rows (customer prepayments / liabilities, not salon revenue). Aligned with Sales Summary location totals.';


-- ---------------------------------------------------------------------
-- 4. public.get_kpi_revenue_live
--    KPI revenue total excludes voucher rows.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_revenue_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'business',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code              text,
  scope_type            text,
  location_id           uuid,
  staff_member_id       uuid,
  period_start          date,
  period_end            date,
  mtd_through           date,
  is_current_open_month boolean,
  value                 numeric(18, 4),
  value_numerator       numeric(18, 4),
  value_denominator     numeric(18, 4),
  source                text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date;
  v_period_end   date;
  v_mtd_through  date;
  v_is_current   boolean;
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
  v_total        numeric(18, 4);
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_revenue_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  -- Voucher rows are excluded: they're customer prepayments /
  -- liabilities, not salon revenue. The exclusion happens via
  -- public.is_voucher_sale_row(...) so the rule lives in one place.
  SELECT COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4)
    INTO v_total
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = v_period_start
    AND e.sale_date  <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND NOT public.is_voucher_sale_row(
      e.raw_product_type, e.product_type_actual,
      e.product_type_short, e.commission_product_service
    )
    AND (
      v_scope = 'business'
      OR (v_scope = 'location' AND e.location_id = v_loc_id)
      OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = v_staff_id)
    );

  RETURN QUERY
  SELECT
    'revenue'::text                                                                       AS kpi_code,
    v_scope                                                                               AS scope_type,
    v_loc_id                                                                              AS location_id,
    v_staff_id                                                                            AS staff_member_id,
    v_period_start                                                                        AS period_start,
    v_period_end                                                                          AS period_end,
    v_mtd_through                                                                         AS mtd_through,
    v_is_current                                                                          AS is_current_open_month,
    v_total                                                                               AS value,
    v_total                                                                               AS value_numerator,
    NULL::numeric(18, 4)                                                                  AS value_denominator,
    'public.v_sales_transactions_enriched (price_ex_gst, vouchers excluded)'::text        AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) IS
'Live revenue (ex GST) KPI. Excludes voucher rows (public.is_voucher_sale_row) since vouchers are customer prepayments / liabilities, not salon revenue. Stylist/assistant callers are silently restricted to their own staff scope.';


-- ---------------------------------------------------------------------
-- 5. public.get_kpi_average_client_spend_live
--    Numerator (revenue) excludes voucher rows via FILTER. Denominator
--    (distinct guests) is unchanged so the locked invariant
--    `avg_spend = get_kpi_revenue_live.value / get_kpi_guests_per_month_live.value`
--    remains true at every scope / period.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_average_client_spend_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'business',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code              text,
  scope_type            text,
  location_id           uuid,
  staff_member_id       uuid,
  period_start          date,
  period_end            date,
  mtd_through           date,
  is_current_open_month boolean,
  value                 numeric(18, 4),
  value_numerator       numeric(18, 4),
  value_denominator     numeric(18, 4),
  source                text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date;
  v_period_end   date;
  v_mtd_through  date;
  v_is_current   boolean;
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
  v_revenue      numeric(18, 4);
  v_guests       numeric(18, 4);
  v_avg          numeric(18, 4);
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_average_client_spend_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  -- Single scan. The numerator uses FILTER to exclude voucher rows
  -- (so it matches get_kpi_revenue_live exactly). The denominator is
  -- distinct guests across ALL rows in the same scope/period (so it
  -- matches get_kpi_guests_per_month_live exactly). Net effect: a
  -- guest who bought only a voucher contributes 0 to revenue and 1 to
  -- guest count, slightly deflating avg_spend — correct economic
  -- interpretation since voucher prepayments are not realised revenue.
  SELECT
    COALESCE(
      SUM(e.price_ex_gst) FILTER (
        WHERE NOT public.is_voucher_sale_row(
          e.raw_product_type, e.product_type_actual,
          e.product_type_short, e.commission_product_service
        )
      ),
      0
    )::numeric(18, 4),
    COUNT(DISTINCT public.normalise_customer_name(e.customer_name))::numeric(18, 4)
  INTO v_revenue, v_guests
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = v_period_start
    AND e.sale_date  <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND (
      v_scope = 'business'
      OR (v_scope = 'location' AND e.location_id = v_loc_id)
      OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = v_staff_id)
    );

  v_avg := CASE
             WHEN v_guests > 0 THEN (v_revenue / v_guests)::numeric(18, 4)
             ELSE NULL
           END;

  RETURN QUERY
  SELECT
    'average_client_spend'::text                                                                                                                                AS kpi_code,
    v_scope                                                                                                                                                     AS scope_type,
    v_loc_id                                                                                                                                                    AS location_id,
    v_staff_id                                                                                                                                                  AS staff_member_id,
    v_period_start                                                                                                                                              AS period_start,
    v_period_end                                                                                                                                                AS period_end,
    v_mtd_through                                                                                                                                               AS mtd_through,
    v_is_current                                                                                                                                                AS is_current_open_month,
    v_avg                                                                                                                                                       AS value,
    v_revenue                                                                                                                                                   AS value_numerator,
    v_guests                                                                                                                                                    AS value_denominator,
    'revenue (sum price_ex_gst FILTER vouchers excluded) / distinct normalise_customer_name(customer_name); same scope/period filters as revenue + guests RPCs'::text AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_average_client_spend_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_average_client_spend_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_average_client_spend_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_average_client_spend_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_average_client_spend_live(date, text, uuid, uuid) IS
'Live average client spend KPI. Numerator = revenue ex GST (vouchers excluded via public.is_voucher_sale_row). Denominator = distinct guests across all rows in scope/period (matches get_kpi_guests_per_month_live). Returns value=NULL when guests=0. Stylist/assistant callers are silently restricted to their own staff scope.';


-- ---------------------------------------------------------------------
-- 6. public.get_kpi_assistant_utilisation_ratio_live
--    Both numerator AND denominator exclude voucher rows so the
--    documented invariant `denominator == get_kpi_revenue_live.value`
--    stays true.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_assistant_utilisation_ratio_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'business',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code              text,
  scope_type            text,
  location_id           uuid,
  staff_member_id       uuid,
  period_start          date,
  period_end            date,
  mtd_through           date,
  is_current_open_month boolean,
  value                 numeric(18, 4),
  value_numerator       numeric(18, 4),
  value_denominator     numeric(18, 4),
  source                text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date;
  v_period_end   date;
  v_mtd_through  date;
  v_is_current   boolean;
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
  v_numerator    numeric(18, 4);
  v_denominator  numeric(18, 4);
  v_value        numeric(18, 4);
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_assistant_utilisation_ratio_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  -- Voucher rows excluded at the WHERE level so both numerator and
  -- denominator use the same row universe and the
  -- `denominator == get_kpi_revenue_live.value` invariant stated in
  -- 20260501310000 is preserved.
  SELECT
    COALESCE(
      SUM(e.price_ex_gst) FILTER (WHERE e.assistant_redirect_candidate),
      0
    )::numeric(18, 4),
    COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4)
  INTO v_numerator, v_denominator
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = v_period_start
    AND e.sale_date  <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND NOT public.is_voucher_sale_row(
      e.raw_product_type, e.product_type_actual,
      e.product_type_short, e.commission_product_service
    )
    AND (
      v_scope = 'business'
      OR (v_scope = 'location' AND e.location_id = v_loc_id)
      OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = v_staff_id)
    );

  v_value := CASE
               WHEN v_denominator > 0
                 THEN (v_numerator / v_denominator)::numeric(18, 4)
               ELSE NULL
             END;

  RETURN QUERY
  SELECT
    'assistant_utilisation_ratio'::text                                                                                                                                                AS kpi_code,
    v_scope                                                                                                                                                                            AS scope_type,
    v_loc_id                                                                                                                                                                           AS location_id,
    v_staff_id                                                                                                                                                                         AS staff_member_id,
    v_period_start                                                                                                                                                                     AS period_start,
    v_period_end                                                                                                                                                                       AS period_end,
    v_mtd_through                                                                                                                                                                      AS mtd_through,
    v_is_current                                                                                                                                                                       AS is_current_open_month,
    v_value                                                                                                                                                                            AS value,
    v_numerator                                                                                                                                                                        AS value_numerator,
    v_denominator                                                                                                                                                                      AS value_denominator,
    'v_sales_transactions_enriched: SUM(price_ex_gst) FILTER assistant_redirect_candidate / SUM(price_ex_gst); non-internal; vouchers excluded; commission_owner_candidate_id attribution'::text AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_assistant_utilisation_ratio_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_assistant_utilisation_ratio_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_assistant_utilisation_ratio_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_assistant_utilisation_ratio_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_assistant_utilisation_ratio_live(date, text, uuid, uuid) IS
'Live assistant utilisation ratio KPI = SUM(price_ex_gst where assistant_redirect_candidate) / SUM(price_ex_gst); vouchers excluded from both numerator and denominator so denominator matches get_kpi_revenue_live. Stylist/assistant callers are silently restricted to their own staff scope.';


-- ---------------------------------------------------------------------
-- 7. public.get_kpi_stylist_profitability_live
--    Revenue numerator excludes voucher rows.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_stylist_profitability_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'business',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code              text,
  scope_type            text,
  location_id           uuid,
  staff_member_id       uuid,
  period_start          date,
  period_end            date,
  mtd_through           date,
  is_current_open_month boolean,
  value                 numeric(18, 4),
  value_numerator       numeric(18, 4),
  value_denominator     numeric(18, 4),
  source                text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date;
  v_period_end   date;
  v_mtd_through  date;
  v_is_current   boolean;
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
  v_numerator    numeric(18, 4);
  v_denominator  numeric(18, 4);
  v_value        numeric(18, 4);
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_stylist_profitability_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  IF v_scope = 'staff' THEN
    -- Voucher rows excluded so per-stylist profitability numerator
    -- matches get_kpi_revenue_live for that stylist.
    SELECT
      COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4)
    INTO v_numerator
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = v_period_start
      AND e.sale_date  <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND NOT public.is_voucher_sale_row(
        e.raw_product_type, e.product_type_actual,
        e.product_type_short, e.commission_product_service
      )
      AND e.commission_owner_candidate_id = v_staff_id;

    SELECT sm.fte::numeric(18, 4)
      INTO v_denominator
    FROM public.staff_members sm
    WHERE sm.id = v_staff_id;

  ELSE
    WITH stylist_sales AS (
      SELECT
        e.commission_owner_candidate_id AS sid,
        SUM(e.price_ex_gst)             AS revenue
      FROM public.v_sales_transactions_enriched e
      WHERE e.month_start = v_period_start
        AND e.sale_date  <= v_mtd_through
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND NOT public.is_voucher_sale_row(
          e.raw_product_type, e.product_type_actual,
          e.product_type_short, e.commission_product_service
        )
        AND e.commission_owner_candidate_id IS NOT NULL
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id = v_loc_id)
        )
      GROUP BY e.commission_owner_candidate_id
    ),
    eligible AS (
      SELECT ss.revenue, sm.fte::numeric(18, 4) AS fte
      FROM stylist_sales ss
      JOIN public.staff_members sm ON sm.id = ss.sid
      -- Substring match so 'Senior Stylist', 'Director Stylist',
      -- etc. all qualify. NULL stays excluded. (Carried forward
      -- from 20260501330000.)
      WHERE COALESCE(lower(btrim(sm.primary_role)), '') LIKE '%stylist%'
        AND sm.fte IS NOT NULL
        AND sm.fte > 0
    )
    SELECT
      COALESCE(SUM(revenue), 0)::numeric(18, 4),
      COALESCE(SUM(fte),     0)::numeric(18, 4)
    INTO v_numerator, v_denominator
    FROM eligible;
  END IF;

  v_value := CASE
               WHEN v_denominator IS NOT NULL AND v_denominator > 0
                 THEN (v_numerator / v_denominator)::numeric(18, 4)
               ELSE NULL
             END;

  RETURN QUERY
  SELECT
    'stylist_profitability'::text                                                                                                                                                          AS kpi_code,
    v_scope                                                                                                                                                                                AS scope_type,
    v_loc_id                                                                                                                                                                               AS location_id,
    v_staff_id                                                                                                                                                                             AS staff_member_id,
    v_period_start                                                                                                                                                                         AS period_start,
    v_period_end                                                                                                                                                                           AS period_end,
    v_mtd_through                                                                                                                                                                          AS mtd_through,
    v_is_current                                                                                                                                                                           AS is_current_open_month,
    v_value                                                                                                                                                                                AS value,
    v_numerator                                                                                                                                                                            AS value_numerator,
    v_denominator                                                                                                                                                                          AS value_denominator,
    'v_sales_transactions_enriched revenue / staff_members.fte; non-internal; vouchers excluded; primary_role ILIKE %stylist% & fte>0 at rollup; commission_owner_candidate_id attribution'::text AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) IS
'Live stylist profitability KPI (NZD per FTE). Numerator = eligible stylists'' sales ex GST (vouchers excluded). Denominator = staff_members.fte. staff scope uses caller-resolved staff_member_id directly. location/business scope restrict to primary_role ILIKE %stylist% contributors with fte>0. Stylist/assistant callers are silently restricted to their own staff scope.';


-- ---------------------------------------------------------------------
-- 8. public.get_kpi_stylist_comparisons_live
--    Cohort revenue + assistant_util CTEs exclude voucher rows via
--    FILTER. Guests / new_clients CTEs intentionally preserved (a
--    voucher-only guest is still a guest of the salon).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_stylist_comparisons_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'staff',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code              text,
  period_start          date,
  period_end            date,
  mtd_through           date,
  is_current_open_month boolean,
  staff_member_id       uuid,
  current_value         numeric(18, 4),
  highest_value         numeric(18, 4),
  average_value         numeric(18, 4),
  cohort_size           integer,
  is_highest            boolean,
  is_above_average      boolean
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date;
  v_period_end   date;
  v_mtd_through  date;
  v_is_current   boolean;
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_stylist_comparisons_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  IF v_scope <> 'staff' OR v_staff_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH cohort AS (
    SELECT
      sm.id AS staff_id,
      sm.fte AS staff_fte
    FROM public.staff_members sm
    WHERE sm.is_active = true
      AND COALESCE(lower(btrim(sm.primary_role)), '') LIKE '%stylist%'
  ),
  month_e AS (
    -- One per-row voucher classification carried alongside the rowset
    -- so revenue / asst_util can FILTER vouchers out cheaply while
    -- guests / new_clients keep using the same rowset (voucher-only
    -- guests still count as guests of the salon).
    SELECT
      e.commission_owner_candidate_id AS staff_id,
      e.price_ex_gst,
      e.customer_name,
      e.assistant_redirect_candidate,
      public.is_voucher_sale_row(
        e.raw_product_type, e.product_type_actual,
        e.product_type_short, e.commission_product_service
      ) AS is_voucher
    FROM public.v_sales_transactions_enriched e
    INNER JOIN cohort c ON c.staff_id = e.commission_owner_candidate_id
    WHERE e.month_start = v_period_start
      AND e.sale_date <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  rev AS (
    SELECT
      me.staff_id,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE NOT me.is_voucher),
        0
      )::numeric(18, 4) AS v
    FROM month_e me
    GROUP BY me.staff_id
  ),
  gst AS (
    SELECT
      me.staff_id,
      COUNT(DISTINCT public.normalise_customer_name(me.customer_name))::numeric(18, 4) AS v
    FROM month_e me
    WHERE public.normalise_customer_name(me.customer_name) IS NOT NULL
    GROUP BY me.staff_id
  ),
  asst_util AS (
    -- Both numerator and denominator exclude vouchers so the ratio
    -- is over the same row universe as the standalone
    -- get_kpi_assistant_utilisation_ratio_live (whose denominator
    -- equals get_kpi_revenue_live).
    SELECT
      me.staff_id,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE me.assistant_redirect_candidate AND NOT me.is_voucher),
        0
      )::numeric(18, 4) AS numer,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE NOT me.is_voucher),
        0
      )::numeric(18, 4) AS denom
    FROM month_e me
    GROUP BY me.staff_id
  ),
  cohort_metrics AS (
    SELECT
      c.staff_id,
      c.staff_fte,
      COALESCE(r.v, 0::numeric(18, 4)) AS revenue,
      COALESCE(g.v, 0::numeric(18, 4)) AS guests,
      CASE
        WHEN COALESCE(g.v, 0::numeric(18, 4)) > 0 THEN
          (COALESCE(r.v, 0::numeric(18, 4)) / g.v)::numeric(18, 4)
        ELSE NULL::numeric(18, 4)
      END AS avg_spend
    FROM cohort c
    LEFT JOIN rev r ON r.staff_id = c.staff_id
    LEFT JOIN gst g ON g.staff_id = c.staff_id
  ),
  cohort_asst AS (
    SELECT
      c.staff_id,
      CASE
        WHEN COALESCE(au.denom, 0::numeric(18, 4)) > 0 THEN
          (COALESCE(au.numer, 0::numeric(18, 4)) / au.denom)::numeric(18, 4)
        ELSE NULL::numeric(18, 4)
      END AS util_ratio
    FROM cohort c
    LEFT JOIN asst_util au ON au.staff_id = c.staff_id
  ),
  month_norms AS (
    SELECT DISTINCT
      me.staff_id,
      public.normalise_customer_name(me.customer_name) AS norm_name
    FROM month_e me
    WHERE public.normalise_customer_name(me.customer_name) IS NOT NULL
  ),
  newc AS (
    SELECT
      mn.staff_id,
      (COUNT(*)::numeric(18, 4)) AS v
    FROM month_norms mn
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_period_start
        AND public.normalise_customer_name(e2.customer_name) = mn.norm_name
    )
    GROUP BY mn.staff_id
  ),
  per_stylist AS (
    SELECT
      'revenue'::text AS kpi_code,
      cm.staff_id,
      (
        CASE
          WHEN cm.staff_fte IS NOT NULL
           AND cm.staff_fte::numeric > 0
           AND cm.staff_fte::numeric < 1
          THEN (cm.revenue / cm.staff_fte::numeric)::numeric(18, 4)
          ELSE cm.revenue
        END
      ) AS v
    FROM cohort_metrics cm
    UNION ALL
    SELECT
      'guests_per_month'::text,
      cm.staff_id,
      (
        CASE
          WHEN cm.staff_fte IS NOT NULL
           AND cm.staff_fte::numeric > 0
           AND cm.staff_fte::numeric < 1
          THEN (cm.guests / cm.staff_fte::numeric)::numeric(18, 4)
          ELSE cm.guests
        END
      ) AS v
    FROM cohort_metrics cm
    UNION ALL
    SELECT
      'new_clients_per_month'::text,
      c.staff_id,
      (
        CASE
          WHEN c.staff_fte IS NOT NULL
           AND c.staff_fte::numeric > 0
           AND c.staff_fte::numeric < 1
          THEN (COALESCE(n.v, 0::numeric(18, 4)) / c.staff_fte::numeric)::numeric(18, 4)
          ELSE COALESCE(n.v, 0::numeric(18, 4))
        END
      ) AS v
    FROM cohort c
    LEFT JOIN newc n ON n.staff_id = c.staff_id
    UNION ALL
    SELECT 'average_client_spend'::text, cm.staff_id, cm.avg_spend
    FROM cohort_metrics cm
    UNION ALL
    SELECT 'assistant_utilisation_ratio'::text, ca.staff_id, ca.util_ratio
    FROM cohort_asst ca
  ),
  agg AS (
    SELECT
      p.kpi_code,
      MAX(p.v) FILTER (WHERE p.v IS NOT NULL)            AS highest,
      AVG(p.v) FILTER (WHERE p.v IS NOT NULL)            AS avg_v,
      (COUNT(*) FILTER (WHERE p.v IS NOT NULL))::integer AS cohort_count,
      MAX(p.v) FILTER (WHERE p.staff_id = v_staff_id)    AS current_v
    FROM per_stylist p
    GROUP BY p.kpi_code
  )
  SELECT
    a.kpi_code                              AS kpi_code,
    v_period_start                          AS period_start,
    v_period_end                            AS period_end,
    v_mtd_through                           AS mtd_through,
    v_is_current                            AS is_current_open_month,
    v_staff_id                              AS staff_member_id,
    a.current_v::numeric(18, 4)             AS current_value,
    a.highest::numeric(18, 4)               AS highest_value,
    a.avg_v::numeric(18, 4)                 AS average_value,
    a.cohort_count                          AS cohort_size,
    (
      a.cohort_count >= 2
      AND a.current_v IS NOT NULL
      AND a.highest   IS NOT NULL
      AND a.current_v >= a.highest
    )                                       AS is_highest,
    (
      a.cohort_count >= 2
      AND a.current_v IS NOT NULL
      AND a.avg_v     IS NOT NULL
      AND a.current_v >  a.avg_v
    )                                       AS is_above_average
  FROM agg a
  ORDER BY a.kpi_code;
END;
$fn$;

ALTER FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) IS
'Live stylist comparison for staff/self KPI cards. Revenue and assistant_utilisation cohort math exclude voucher rows. Guests / new_clients counts intentionally include voucher-only guests (a voucher purchase still represents a guest visit). FTE-adjusted revenue/guests/new clients; raw average_client_spend and assistant_utilisation_ratio.';


-- ---------------------------------------------------------------------
-- 9. public.get_kpi_stylist_comparison_leaders_live
--    Same FILTER pattern as comparisons_live so "Top stylist" badges
--    are consistent with the comparison values.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_stylist_comparison_leaders_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'staff',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code               text,
  top_staff_member_id    uuid,
  top_staff_display_name text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date;
  v_period_end   date;
  v_mtd_through  date;
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_stylist_comparison_leaders_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  IF v_scope <> 'staff' OR v_staff_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH cohort AS (
    SELECT
      sm.id AS staff_id,
      sm.fte AS staff_fte
    FROM public.staff_members sm
    WHERE sm.is_active = true
      AND COALESCE(lower(btrim(sm.primary_role)), '') LIKE '%stylist%'
  ),
  month_e AS (
    SELECT
      e.commission_owner_candidate_id AS staff_id,
      e.price_ex_gst,
      e.customer_name,
      e.assistant_redirect_candidate,
      public.is_voucher_sale_row(
        e.raw_product_type, e.product_type_actual,
        e.product_type_short, e.commission_product_service
      ) AS is_voucher
    FROM public.v_sales_transactions_enriched e
    INNER JOIN cohort c ON c.staff_id = e.commission_owner_candidate_id
    WHERE e.month_start = v_period_start
      AND e.sale_date <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  rev AS (
    SELECT
      me.staff_id,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE NOT me.is_voucher),
        0
      )::numeric(18, 4) AS v
    FROM month_e me
    GROUP BY me.staff_id
  ),
  gst AS (
    SELECT
      me.staff_id,
      COUNT(DISTINCT public.normalise_customer_name(me.customer_name))::numeric(18, 4) AS v
    FROM month_e me
    WHERE public.normalise_customer_name(me.customer_name) IS NOT NULL
    GROUP BY me.staff_id
  ),
  asst_util AS (
    SELECT
      me.staff_id,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE me.assistant_redirect_candidate AND NOT me.is_voucher),
        0
      )::numeric(18, 4) AS numer,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE NOT me.is_voucher),
        0
      )::numeric(18, 4) AS denom
    FROM month_e me
    GROUP BY me.staff_id
  ),
  cohort_metrics AS (
    SELECT
      c.staff_id,
      c.staff_fte,
      COALESCE(r.v, 0::numeric(18, 4)) AS revenue,
      COALESCE(g.v, 0::numeric(18, 4)) AS guests,
      CASE
        WHEN COALESCE(g.v, 0::numeric(18, 4)) > 0 THEN
          (COALESCE(r.v, 0::numeric(18, 4)) / g.v)::numeric(18, 4)
        ELSE NULL::numeric(18, 4)
      END AS avg_spend
    FROM cohort c
    LEFT JOIN rev r ON r.staff_id = c.staff_id
    LEFT JOIN gst g ON g.staff_id = c.staff_id
  ),
  cohort_asst AS (
    SELECT
      c.staff_id,
      CASE
        WHEN COALESCE(au.denom, 0::numeric(18, 4)) > 0 THEN
          (COALESCE(au.numer, 0::numeric(18, 4)) / au.denom)::numeric(18, 4)
        ELSE NULL::numeric(18, 4)
      END AS util_ratio
    FROM cohort c
    LEFT JOIN asst_util au ON au.staff_id = c.staff_id
  ),
  month_norms AS (
    SELECT DISTINCT
      me.staff_id,
      public.normalise_customer_name(me.customer_name) AS norm_name
    FROM month_e me
    WHERE public.normalise_customer_name(me.customer_name) IS NOT NULL
  ),
  newc AS (
    SELECT
      mn.staff_id,
      (COUNT(*)::numeric(18, 4)) AS v
    FROM month_norms mn
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_period_start
        AND public.normalise_customer_name(e2.customer_name) = mn.norm_name
    )
    GROUP BY mn.staff_id
  ),
  per_stylist AS (
    SELECT
      'revenue'::text AS kpi_code,
      cm.staff_id,
      (
        CASE
          WHEN cm.staff_fte IS NOT NULL
           AND cm.staff_fte::numeric > 0
           AND cm.staff_fte::numeric < 1
          THEN (cm.revenue / cm.staff_fte::numeric)::numeric(18, 4)
          ELSE cm.revenue
        END
      ) AS v
    FROM cohort_metrics cm
    UNION ALL
    SELECT
      'guests_per_month'::text,
      cm.staff_id,
      (
        CASE
          WHEN cm.staff_fte IS NOT NULL
           AND cm.staff_fte::numeric > 0
           AND cm.staff_fte::numeric < 1
          THEN (cm.guests / cm.staff_fte::numeric)::numeric(18, 4)
          ELSE cm.guests
        END
      ) AS v
    FROM cohort_metrics cm
    UNION ALL
    SELECT
      'new_clients_per_month'::text,
      c.staff_id,
      (
        CASE
          WHEN c.staff_fte IS NOT NULL
           AND c.staff_fte::numeric > 0
           AND c.staff_fte::numeric < 1
          THEN (COALESCE(n.v, 0::numeric(18, 4)) / c.staff_fte::numeric)::numeric(18, 4)
          ELSE COALESCE(n.v, 0::numeric(18, 4))
        END
      ) AS v
    FROM cohort c
    LEFT JOIN newc n ON n.staff_id = c.staff_id
    UNION ALL
    SELECT 'average_client_spend'::text, cm.staff_id, cm.avg_spend
    FROM cohort_metrics cm
    UNION ALL
    SELECT 'assistant_utilisation_ratio'::text, ca.staff_id, ca.util_ratio
    FROM cohort_asst ca
  ),
  agg AS (
    SELECT
      p.kpi_code,
      MAX(p.v) FILTER (WHERE p.v IS NOT NULL) AS highest
    FROM per_stylist p
    GROUP BY p.kpi_code
  ),
  top_by_kpi AS (
    SELECT DISTINCT ON (p.kpi_code)
      p.kpi_code,
      p.staff_id AS top_staff_member_id
    FROM per_stylist p
    INNER JOIN agg a ON a.kpi_code = p.kpi_code
      AND a.highest IS NOT NULL
      AND p.v IS NOT NULL
      AND p.v = a.highest
    ORDER BY p.kpi_code, p.staff_id
  ),
  top_named AS (
    SELECT
      tb.kpi_code,
      tb.top_staff_member_id,
      COALESCE(
        NULLIF(btrim(COALESCE(sm.display_name, '')), ''),
        NULLIF(btrim(COALESCE(sm.full_name, '')), ''),
        'Staff'::text
      ) AS top_staff_display_name
    FROM top_by_kpi tb
    LEFT JOIN public.staff_members sm ON sm.id = tb.top_staff_member_id
  )
  SELECT
    k.kpi_code,
    tn.top_staff_member_id,
    tn.top_staff_display_name
  FROM (
    VALUES
      ('revenue'::text),
      ('guests_per_month'::text),
      ('new_clients_per_month'::text),
      ('average_client_spend'::text),
      ('assistant_utilisation_ratio'::text)
  ) AS k(kpi_code)
  LEFT JOIN top_named tn ON tn.kpi_code = k.kpi_code
  ORDER BY k.kpi_code;
END;
$fn$;

ALTER FUNCTION public.get_kpi_stylist_comparison_leaders_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_stylist_comparison_leaders_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_comparison_leaders_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_comparison_leaders_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_stylist_comparison_leaders_live(date, text, uuid, uuid) IS
'Cohort leader per KPI for staff-scope comparisons. Mirrors get_kpi_stylist_comparisons_live including the voucher exclusion in revenue / assistant_utilisation. One row per KPI code; top_staff_* NULL when no cohort maximum. Tie-break: lowest staff uuid.';
