-- =====================================================================
-- KPI live RPC + debug mirror: assistant_utilisation_ratio.
--
-- Locked definition (docs/KPI App Architecture.md §8):
--   assistant_utilisation_ratio
--     = assistant-helped sales ex GST / total eligible sales ex GST
--
-- Source: public.v_sales_transactions_enriched. Same base used by
-- revenue / guests_per_month / new_clients_per_month /
-- average_client_spend, so all five live KPIs share one universe of
-- rows and reconcile against one filter definition.
--
-- Why v_sales_transactions_enriched and NOT v_commission_calculations_core
-- ----------------------------------------------------------------------
-- assistant_redirect_candidate (boolean) and commission_owner_candidate_id
-- are both derived in v_sales_transactions_enriched. The KPI only needs
-- (a) raw price_ex_gst, (b) that boolean flag, and (c) the post-redirect
-- owner for per-stylist attribution. v_commission_calculations_core is
-- about commission RATES and PAYABLE AMOUNTS (derived commission %,
-- assistant_commission_amt_ex_gst, calculation_alert). None of that is
-- in the KPI formula, and routing through core would unnecessarily
-- couple this KPI to commission-rate calculation rules that can shift
-- independently.
--
-- Definition choices
-- ------------------
--   * Numerator   = SUM(price_ex_gst) FILTER (WHERE assistant_redirect_candidate)
--                   at the requested scope, MTD-clipped, non-internal.
--   * Denominator = SUM(price_ex_gst) at the requested scope, MTD-clipped,
--                   non-internal. This makes the denominator
--                   definitionally equal to get_kpi_revenue_live.value
--                   at the same scope/period.
--   * "Eligible"  = existing commission pipeline's eligibility
--                   (non-internal). We do NOT restrict to service class;
--                   if product later wants a service-only variant, it
--                   can be added as a separate KPI without touching
--                   this one.
--   * Attribution = commission_owner_candidate_id (post-assistant-redirect
--                   owner), so a line done by an assistant and redirected
--                   to a senior stylist is credited to the senior stylist
--                   in BOTH numerator (as assistant-helped) and
--                   denominator (as the stylist's sales total). That
--                   matches the payroll/commission layer's definition
--                   of "the stylist's sales" exactly.
--   * Value       = numerator / denominator, returned as a raw ratio
--                   in [0,1]. NULL when denominator = 0 (numerator and
--                   denominator are still populated so the caller can
--                   distinguish "no data" from "zero assistant usage").
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_assistant_utilisation_ratio_live  (auth-enforced)
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

  -- Single scan. FILTER is used so numerator and denominator come
  -- from exactly the same row set (same MTD clip, same scope, same
  -- internal exclusion) — only the assistant_redirect_candidate flag
  -- distinguishes them. This guarantees value = numerator / denominator
  -- and matches get_kpi_revenue_live on the denominator.
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
    'assistant_utilisation_ratio'::text                                                                                                                 AS kpi_code,
    v_scope                                                                                                                                             AS scope_type,
    v_loc_id                                                                                                                                            AS location_id,
    v_staff_id                                                                                                                                          AS staff_member_id,
    v_period_start                                                                                                                                      AS period_start,
    v_period_end                                                                                                                                        AS period_end,
    v_mtd_through                                                                                                                                       AS mtd_through,
    v_is_current                                                                                                                                        AS is_current_open_month,
    v_value                                                                                                                                             AS value,
    v_numerator                                                                                                                                         AS value_numerator,
    v_denominator                                                                                                                                       AS value_denominator,
    'v_sales_transactions_enriched: SUM(price_ex_gst) FILTER assistant_redirect_candidate / SUM(price_ex_gst); non-internal; commission_owner_candidate_id attribution'::text AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_assistant_utilisation_ratio_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_assistant_utilisation_ratio_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_assistant_utilisation_ratio_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_assistant_utilisation_ratio_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_assistant_utilisation_ratio_live(date, text, uuid, uuid) IS
'Live assistant utilisation ratio KPI = SUM(price_ex_gst where assistant_redirect_candidate) / SUM(price_ex_gst) at the same scope/period. Denominator matches get_kpi_revenue_live. Stylist/assistant callers are silently restricted to their own staff scope.';


-- =====================================================================
-- 2. private.debug_kpi_assistant_utilisation_ratio  (validation only)
--
-- Same SQL body as the live RPC, minus the auth wrapper. Adds a
-- row_count column for sanity-checking. Not exposed via PostgREST.
-- Drop when the v1 KPI validation phase is over, alongside the
-- other debug_kpi_* helpers.
-- =====================================================================

CREATE OR REPLACE FUNCTION private.debug_kpi_assistant_utilisation_ratio(
  p_period_start    date,
  p_scope           text DEFAULT 'business',
  p_location_id     uuid DEFAULT NULL,
  p_staff_member_id uuid DEFAULT NULL
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
  source                text,
  row_count             bigint,
  assistant_row_count   bigint
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date := COALESCE(p_period_start, date_trunc('month', current_date)::date);
  v_period_end   date;
  v_mtd_through  date;
  v_is_current   boolean;
  v_scope        text := COALESCE(NULLIF(btrim(p_scope), ''), 'business');
  v_numerator    numeric(18, 4);
  v_denominator  numeric(18, 4);
  v_value        numeric(18, 4);
  v_rows         bigint;
  v_asst_rows    bigint;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION 'debug_kpi_assistant_utilisation_ratio: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_assistant_utilisation_ratio: invalid scope %', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_assistant_utilisation_ratio: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_assistant_utilisation_ratio: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT
    COALESCE(
      SUM(e.price_ex_gst) FILTER (WHERE e.assistant_redirect_candidate),
      0
    )::numeric(18, 4),
    COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4),
    COUNT(*),
    COUNT(*) FILTER (WHERE e.assistant_redirect_candidate)
  INTO v_numerator, v_denominator, v_rows, v_asst_rows
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = v_period_start
    AND e.sale_date  <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND (
      v_scope = 'business'
      OR (v_scope = 'location' AND e.location_id = p_location_id)
      OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = p_staff_member_id)
    );

  v_value := CASE
               WHEN v_denominator > 0
                 THEN (v_numerator / v_denominator)::numeric(18, 4)
               ELSE NULL
             END;

  RETURN QUERY
  SELECT
    'assistant_utilisation_ratio'::text                                                                                                                 AS kpi_code,
    v_scope                                                                                                                                             AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END                                                                                               AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END                                                                                           AS staff_member_id,
    v_period_start                                                                                                                                      AS period_start,
    v_period_end                                                                                                                                        AS period_end,
    v_mtd_through                                                                                                                                       AS mtd_through,
    v_is_current                                                                                                                                        AS is_current_open_month,
    v_value                                                                                                                                             AS value,
    v_numerator                                                                                                                                         AS value_numerator,
    v_denominator                                                                                                                                       AS value_denominator,
    'v_sales_transactions_enriched: SUM(price_ex_gst) FILTER assistant_redirect_candidate / SUM(price_ex_gst); non-internal; commission_owner_candidate_id attribution'::text AS source,
    v_rows                                                                                                                                              AS row_count,
    v_asst_rows                                                                                                                                         AS assistant_row_count;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_assistant_utilisation_ratio(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_assistant_utilisation_ratio(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_assistant_utilisation_ratio(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_assistant_utilisation_ratio_live without the auth wrapper. Adds row_count / assistant_row_count for sanity-checking. Drop when validation is complete.';
