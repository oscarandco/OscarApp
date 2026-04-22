-- =====================================================================
-- stylist_profitability KPI: broaden stylist-role eligibility rule.
--
-- Problem
-- -------
-- The initial implementation (migration 20260501320000) required an
-- exact match on primary_role:
--
--   COALESCE(lower(btrim(sm.primary_role)), '') = 'stylist'
--
-- Real data uses role labels like 'Senior Stylist', 'Director Stylist',
-- and similar, so no rows matched and contributor_count came back as 0
-- even though staff_members.fte was populated.
--
-- Fix
-- ---
-- Replace the equality with a case-insensitive substring match:
--
--   COALESCE(lower(btrim(sm.primary_role)), '') LIKE '%stylist%'
--
-- This includes every stylist-titled role (Stylist, Senior Stylist,
-- Director Stylist, Assistant Stylist, etc.) and continues to exclude
-- NULL, 'Assistant', 'Manager', 'Receptionist', and any other role
-- label that does not contain the substring 'stylist'.
--
-- No other KPI logic changes:
--   * FTE rule (fte IS NOT NULL AND fte > 0) is unchanged.
--   * staff scope behaviour (no role/active filter) is unchanged.
--   * Non-internal filter, attribution, source view, and return shape
--     are unchanged.
--
-- Scope of this migration: two CREATE OR REPLACE FUNCTION statements,
-- one line of semantic difference each.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_stylist_profitability_live  (auth-enforced)
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
    SELECT
      COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4)
    INTO v_numerator
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = v_period_start
      AND e.sale_date  <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
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
      -- CHANGED: substring match so 'Senior Stylist', 'Director Stylist',
      -- etc. all qualify. NULL stays excluded (COALESCE to ''); roles
      -- without 'stylist' in them (Assistant, Manager, Receptionist)
      -- stay excluded as before.
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
    'stylist_profitability'::text                                                                                                                                AS kpi_code,
    v_scope                                                                                                                                                      AS scope_type,
    v_loc_id                                                                                                                                                     AS location_id,
    v_staff_id                                                                                                                                                   AS staff_member_id,
    v_period_start                                                                                                                                               AS period_start,
    v_period_end                                                                                                                                                 AS period_end,
    v_mtd_through                                                                                                                                                AS mtd_through,
    v_is_current                                                                                                                                                 AS is_current_open_month,
    v_value                                                                                                                                                      AS value,
    v_numerator                                                                                                                                                  AS value_numerator,
    v_denominator                                                                                                                                                AS value_denominator,
    'v_sales_transactions_enriched revenue / staff_members.fte; non-internal; primary_role ILIKE %stylist% & fte>0 at rollup; commission_owner_candidate_id attribution'::text AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) IS
'Live stylist profitability KPI (NZD per FTE). Numerator = eligible stylists'' sales ex GST (v_sales_transactions_enriched, non-internal). Denominator = staff_members.fte. staff scope uses the caller-resolved staff_member_id directly. location/business scope restrict to primary_role ILIKE %stylist% contributors with fte>0. Stylist/assistant callers are silently restricted to their own staff scope.';


-- ---------------------------------------------------------------------
-- 2. private.debug_kpi_stylist_profitability  (validation only)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.debug_kpi_stylist_profitability(
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
  contributor_count     bigint,
  row_count             bigint
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
  v_contribs     bigint;
  v_rows         bigint;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION 'debug_kpi_stylist_profitability: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_stylist_profitability: invalid scope %', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_stylist_profitability: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_stylist_profitability: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  IF v_scope = 'staff' THEN
    SELECT
      COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4),
      COUNT(*)
    INTO v_numerator, v_rows
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = v_period_start
      AND e.sale_date  <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND e.commission_owner_candidate_id = p_staff_member_id;

    SELECT sm.fte::numeric(18, 4)
      INTO v_denominator
    FROM public.staff_members sm
    WHERE sm.id = p_staff_member_id;

    v_contribs := CASE
                    WHEN v_denominator IS NOT NULL AND v_denominator > 0 THEN 1
                    ELSE 0
                  END;
  ELSE
    WITH stylist_sales AS (
      SELECT
        e.commission_owner_candidate_id AS sid,
        SUM(e.price_ex_gst)             AS revenue,
        COUNT(*)                        AS line_count
      FROM public.v_sales_transactions_enriched e
      WHERE e.month_start = v_period_start
        AND e.sale_date  <= v_mtd_through
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND e.commission_owner_candidate_id IS NOT NULL
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id = p_location_id)
        )
      GROUP BY e.commission_owner_candidate_id
    ),
    eligible AS (
      SELECT ss.revenue, ss.line_count, sm.fte::numeric(18, 4) AS fte
      FROM stylist_sales ss
      JOIN public.staff_members sm ON sm.id = ss.sid
      -- CHANGED: substring match so 'Senior Stylist', 'Director Stylist',
      -- etc. all qualify. See public function for full notes.
      WHERE COALESCE(lower(btrim(sm.primary_role)), '') LIKE '%stylist%'
        AND sm.fte IS NOT NULL
        AND sm.fte > 0
    )
    SELECT
      COALESCE(SUM(revenue),    0)::numeric(18, 4),
      COALESCE(SUM(fte),        0)::numeric(18, 4),
      COUNT(*),
      COALESCE(SUM(line_count), 0)
    INTO v_numerator, v_denominator, v_contribs, v_rows
    FROM eligible;
  END IF;

  v_value := CASE
               WHEN v_denominator IS NOT NULL AND v_denominator > 0
                 THEN (v_numerator / v_denominator)::numeric(18, 4)
               ELSE NULL
             END;

  RETURN QUERY
  SELECT
    'stylist_profitability'::text                                                                                                                                AS kpi_code,
    v_scope                                                                                                                                                      AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END                                                                                                        AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END                                                                                                    AS staff_member_id,
    v_period_start                                                                                                                                               AS period_start,
    v_period_end                                                                                                                                                 AS period_end,
    v_mtd_through                                                                                                                                                AS mtd_through,
    v_is_current                                                                                                                                                 AS is_current_open_month,
    v_value                                                                                                                                                      AS value,
    v_numerator                                                                                                                                                  AS value_numerator,
    v_denominator                                                                                                                                                AS value_denominator,
    'v_sales_transactions_enriched revenue / staff_members.fte; non-internal; primary_role ILIKE %stylist% & fte>0 at rollup; commission_owner_candidate_id attribution'::text AS source,
    v_contribs                                                                                                                                                   AS contributor_count,
    v_rows                                                                                                                                                       AS row_count;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_stylist_profitability(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_stylist_profitability(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_stylist_profitability(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_stylist_profitability_live without the auth wrapper. Adds contributor_count / row_count for sanity-checking. Drop when validation is complete.';
