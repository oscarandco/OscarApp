-- =====================================================================
-- KPI live RPC + debug mirror: stylist_profitability
--
-- Locked definition (docs/KPI App Architecture.md):
--   stylist_profitability (NZD per FTE, NOT a margin / profit %)
--     = eligible stylist sales ex GST / summed stylist FTE
--
-- Sources
-- -------
--   Sales : public.v_sales_transactions_enriched
--           (same base used by the five already-validated live KPIs;
--            non-internal rows only)
--   FTE   : public.staff_members.fte
--           (locked default. staff_capacity_monthly is NOT the FTE
--            source for this KPI — it remains reserved for
--            capacity/utilisation KPIs.)
--
-- Why NOT v_commission_calculations_core
-- --------------------------------------
-- This KPI only needs raw price_ex_gst and the post-redirect owner
-- (commission_owner_candidate_id), both of which live on
-- v_sales_transactions_enriched. Commission rates / payable amounts
-- are irrelevant to a sales-per-FTE ratio, so going through core
-- would add computation without any benefit.
--
-- Per-scope rules
-- ---------------
--   staff scope (caller picks one staff_member_id):
--     numerator   = SUM(price_ex_gst) credited to that staff_member_id
--                   (non-internal, MTD-clipped, in the requested month).
--     denominator = staff_members.fte for that staff_member_id.
--     value       = n/d. NULL if fte IS NULL or fte <= 0
--                   (numerator still populated so the data-quality
--                   issue is visible to the caller).
--     No primary_role / is_active filter at this scope — the caller
--     has asked for a specific person's ratio.
--
--   location and business scope (rollup):
--     Eligible contributor = staff_members s WHERE
--       s.primary_role = 'stylist'
--       AND s.fte IS NOT NULL AND s.fte > 0
--       AND EXISTS a non-internal, in-period, in-scope sale row
--                  with commission_owner_candidate_id = s.id.
--     numerator   = SUM of contributors' in-scope non-internal sales
--                   ex GST for the period (MTD-clipped).
--     denominator = SUM of contributors' staff_members.fte
--                   (one fte value per contributor, NOT per sale row).
--     value       = n/d. NULL when there are no eligible contributors.
--
-- Documented edge cases
-- ---------------------
--   * NULL fte / fte <= 0 at rollup scope: contributor excluded from
--     BOTH numerator and denominator so the metric stays well-defined.
--     Their sales are still in the revenue KPI. Side-effect:
--     stylist_profitability.value_numerator <= revenue.value at the
--     same scope/period.
--   * is_active = false at rollup scope: NOT filtered. A stylist
--     deactivated mid-period still has sales for that period, so
--     keeping their fte in the denominator preserves n/d symmetry.
--   * Non-stylist primary_role (e.g. 'manager') with commission-
--     credited sales at rollup scope: excluded. Their sales are in
--     the revenue KPI but not here.
--   * Multi-location stylist: each location includes the stylist's
--     full fte in its denominator (against only their in-location
--     sales). Summing location denominators will NOT equal the
--     business denominator when any stylist works multiple locations;
--     the business denominator counts each stylist's fte exactly
--     once. This matches the locked rollup rule.
--   * Retroactive changes to primary_role / fte: the live RPC always
--     reflects current staff_members values. Historical months will
--     be frozen in kpi_monthly_values by the month-close process
--     (separate future step) — the live RPC is for open months only.
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
    -- staff scope: this person's revenue / this person's fte.
    -- No primary_role / is_active filter — caller asked for a
    -- specific id and wants that person's ratio.
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
    -- location / business scope: restrict contributors to active-or-
    -- historical stylists with a usable fte, then sum revenue and
    -- fte across them in one scan.
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
      WHERE COALESCE(lower(btrim(sm.primary_role)), '') = 'stylist'
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
    'stylist_profitability'::text                                                                                                                   AS kpi_code,
    v_scope                                                                                                                                         AS scope_type,
    v_loc_id                                                                                                                                        AS location_id,
    v_staff_id                                                                                                                                      AS staff_member_id,
    v_period_start                                                                                                                                  AS period_start,
    v_period_end                                                                                                                                    AS period_end,
    v_mtd_through                                                                                                                                   AS mtd_through,
    v_is_current                                                                                                                                    AS is_current_open_month,
    v_value                                                                                                                                         AS value,
    v_numerator                                                                                                                                     AS value_numerator,
    v_denominator                                                                                                                                   AS value_denominator,
    'v_sales_transactions_enriched revenue / staff_members.fte; non-internal; primary_role=stylist & fte>0 at rollup; commission_owner_candidate_id attribution'::text AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) IS
'Live stylist profitability KPI (NZD per FTE). Numerator = eligible stylists'' sales ex GST (v_sales_transactions_enriched, non-internal). Denominator = staff_members.fte. staff scope uses the caller-resolved staff_member_id directly. location/business scope restrict to primary_role=stylist contributors with fte>0. Stylist/assistant callers are silently restricted to their own staff scope.';


-- =====================================================================
-- 2. private.debug_kpi_stylist_profitability  (validation only)
--
-- Same SQL body as the live RPC, minus the auth wrapper. Adds
-- contributor_count and row_count columns for sanity-checking.
-- Not exposed via PostgREST. Drop when the v1 KPI validation phase
-- is over, alongside the other debug_kpi_* helpers.
-- =====================================================================

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

    -- Contributor count at staff scope: 1 if the staff row exists
    -- and fte > 0, else 0. Useful for detecting NULL/zero fte.
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
      WHERE COALESCE(lower(btrim(sm.primary_role)), '') = 'stylist'
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
    'stylist_profitability'::text                                                                                                                   AS kpi_code,
    v_scope                                                                                                                                         AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END                                                                                           AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END                                                                                       AS staff_member_id,
    v_period_start                                                                                                                                  AS period_start,
    v_period_end                                                                                                                                    AS period_end,
    v_mtd_through                                                                                                                                   AS mtd_through,
    v_is_current                                                                                                                                    AS is_current_open_month,
    v_value                                                                                                                                         AS value,
    v_numerator                                                                                                                                     AS value_numerator,
    v_denominator                                                                                                                                   AS value_denominator,
    'v_sales_transactions_enriched revenue / staff_members.fte; non-internal; primary_role=stylist & fte>0 at rollup; commission_owner_candidate_id attribution'::text AS source,
    v_contribs                                                                                                                                      AS contributor_count,
    v_rows                                                                                                                                          AS row_count;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_stylist_profitability(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_stylist_profitability(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_stylist_profitability(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_stylist_profitability_live without the auth wrapper. Adds contributor_count / row_count for sanity-checking. Drop when validation is complete.';
