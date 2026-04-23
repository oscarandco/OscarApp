-- =====================================================================
-- KPI fix: new_client_retention_6m / new_client_retention_12m
-- switch to split-window semantics (mirror of client_retention_*).
--
-- Problem
-- -------
-- The previous implementation used a "base/acquisition month + next
-- N calendar months" window, where:
--   * cohort   = clients first-ever-seen in the base month (scope-filtered)
--   * retained = cohort clients who returned at the same scope in the
--                next 6 / 12 calendar months.
-- The locked business rule is now the split-window shape already used
-- by client_retention_*:
--   * first half  = months 1..3 (6m) or 1..6 (12m) of the trailing
--                   6 / 12-month window ending at reporting month M.
--   * second half = months 4..6 (6m) or 7..12 (12m).
--   * base cohort = clients who were NEW to Oscar & Co in the first
--                   half AND served at the requested scope in the
--                   first half.
--   * retained    = those same clients seen by anyone in the business
--                   in the second half (staff scope), or same-location
--                   (location scope), or any row (business scope).
--
-- Fix
-- ---
-- Rewrite the function bodies to use the split-window shape from
-- `20260501480000_kpi_client_retention_staff_scope_fix.sql` and add
-- the NEW-client restriction to the base cohort via a business-wide
-- NOT EXISTS against `sale_date < v_first_half_start` (matches the
-- locked new-client identity rule from new_clients_per_month).
--
-- Scope interpretation
-- --------------------
--   business : base cohort = new clients seen anywhere in the first
--              half; retained = any visit anywhere in the second half.
--   location : base cohort = new clients seen at the requested
--              location in the first half; retained = any visit at
--              the SAME location in the second half (location
--              behaviour preserved; not broadened).
--   staff    : base cohort = new clients served by that stylist in
--              the first half; retained = those same clients seen by
--              ANYONE at Oscar & Co in the second half (new rule,
--              parallels the corrected client_retention_* staff rule).
--
-- Window semantics (reporting month p, first-of-month)
-- ----------------------------------------------------
-- 6m:
--   v_first_half_start  = (p - interval '5 months')
--   v_first_half_end    = ((p - interval '2 months') - 1)
--   v_second_half_start = (p - interval '2 months')
--   v_second_half_end   = LEAST(p + 1 month - 1 day, current_date)
--
-- 12m:
--   v_first_half_start  = (p - interval '11 months')
--   v_first_half_end    = ((p - interval '5 months') - 1)
--   v_second_half_start = (p - interval '5 months')
--   v_second_half_end   = LEAST(p + 1 month - 1 day, current_date)
--
-- Example p = 2026-03-01 (March 2026):
--   6m  first half  = [2025-10-01, 2025-12-31]
--       second half = [2026-01-01, 2026-03-31] (MTD-clipped if current month)
--   12m first half  = [2025-04-01, 2025-09-30]
--       second half = [2025-10-01, 2026-03-31] (MTD-clipped if current month)
--
-- "New client" rule (unchanged identity semantics, now anchored on
-- first-half start instead of base month start):
--   * client_key = public.normalise_customer_name(customer_name)
--   * NEW if no row with sale_date < v_first_half_start exists for
--     that client_key anywhere in v_sales_transactions_enriched.
--   * The history check is NOT internal-excluded (any prior
--     appearance disqualifies), matching new_clients_per_month.
--
-- Internal-line exclusion in first / second half:
--   * Same as client_retention_* and new_clients_per_month —
--     COALESCE(lower(btrim(commission_owner_candidate_name)), '')
--     <> 'internal'.
--
-- RPC return shape
-- ----------------
-- Public RPCs keep the locked 12-column KPI shape (frontend contract
-- preserved). Private debug helpers are rewritten to mirror the
-- debug_kpi_client_retention_* column shape (first_half_start /
-- _end, second_half_start / _end, base_cohort_count, retained_count,
-- row_count_in_window) so the two retention KPI families have
-- parallel diagnostic outputs. This means old columns
-- (is_return_window_complete, base_month_start,
-- base_month_end_observed, return_window_start / _end_full /
-- _end_observed, in_period_guest_count, cohort_count) are gone —
-- DROP + CREATE is required because PostgreSQL doesn't allow
-- CREATE OR REPLACE to change return types.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_new_client_retention_6m_live
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_new_client_retention_6m_live(
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
  v_period_start      date;
  v_period_end        date;
  v_mtd_through       date;
  v_is_current        boolean;
  v_scope             text;
  v_loc_id            uuid;
  v_staff_id          uuid;
  v_first_half_start  date;
  v_first_half_end    date;
  v_second_half_start date;
  v_second_half_end   date;
  v_base              bigint;
  v_retained          bigint;
  v_value             numeric(18, 4);
  v_source            text;
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_new_client_retention_6m_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  v_first_half_start  := (v_period_start - interval '5 months')::date;
  v_first_half_end    := ((v_period_start - interval '2 months')::date - 1);
  v_second_half_start := (v_period_start - interval '2 months')::date;
  v_second_half_end   := v_mtd_through;

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  WITH normed AS (
    SELECT
      public.normalise_customer_name(e.customer_name) AS client_key,
      e.sale_date,
      e.location_id                                   AS loc_id,
      e.commission_owner_candidate_id                 AS owner_id
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_first_half_start AND v_second_half_end
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND public.normalise_customer_name(e.customer_name) <> ''
  ),
  first_half_candidates AS (
    -- Clients served at the requested scope in the first half. These
    -- are the candidates we then filter down to "new" clients via
    -- the business-wide first-ever-seen NOT EXISTS below.
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_first_half_start AND v_first_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = v_loc_id)
        OR (v_scope = 'staff'    AND owner_id = v_staff_id)
      )
  ),
  base_cohort AS (
    -- Restrict first-half candidates to clients whose first-ever
    -- appearance in the business is within the first half (i.e. no
    -- row strictly before v_first_half_start).
    SELECT c.client_key
    FROM first_half_candidates c
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_first_half_start
        AND public.normalise_customer_name(e2.customer_name) = c.client_key
    )
  ),
  second_half_clients AS (
    -- Second-half membership: business → any row, location → same
    -- location, staff → any row at Oscar & Co (same rule as the
    -- corrected client_retention_6m — retained means the cohort
    -- client returned anywhere in the business, not just the same
    -- stylist).
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_second_half_start AND v_second_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id = v_loc_id)
        OR (v_scope = 'staff')
      )
  ),
  retained AS (
    SELECT b.client_key
    FROM base_cohort b
    JOIN second_half_clients s USING (client_key)
  ),
  agg AS (
    SELECT
      (SELECT COUNT(*) FROM base_cohort) AS b_count,
      (SELECT COUNT(*) FROM retained)    AS r_count
  )
  SELECT b_count, r_count
  INTO v_base, v_retained
  FROM agg;

  v_value := CASE
               WHEN v_base > 0
                 THEN (v_retained::numeric / v_base::numeric)::numeric(18, 4)
               ELSE NULL
             END;

  v_source := format(
    'v_sales_transactions_enriched: retained / new-client base cohort; base=[%s,%s] (months 1-3, scoped, first-ever-seen before %s); return=[%s,%s] (months 4-6; business-wide for staff scope); non-internal; scope=%s',
    v_first_half_start, v_first_half_end,
    v_first_half_start,
    v_second_half_start, v_second_half_end,
    v_scope
  );

  RETURN QUERY
  SELECT
    'new_client_retention_6m'::text AS kpi_code,
    v_scope                         AS scope_type,
    v_loc_id                        AS location_id,
    v_staff_id                      AS staff_member_id,
    v_period_start                  AS period_start,
    v_period_end                    AS period_end,
    v_mtd_through                   AS mtd_through,
    v_is_current                    AS is_current_open_month,
    v_value                         AS value,
    v_retained::numeric(18, 4)      AS value_numerator,
    v_base::numeric(18, 4)          AS value_denominator,
    v_source                        AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_new_client_retention_6m_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_new_client_retention_6m_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_new_client_retention_6m_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_new_client_retention_6m_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_new_client_retention_6m_live(date, text, uuid, uuid) IS
'Live 6-month split-window new-client retention KPI. Base cohort = distinct normalise_customer_name who (a) first appear in the business within the first half [p-5m, p-2m-1d] and (b) were served at the requested scope in the first half. Retained = base-cohort clients seen in the second half [p-2m, MTD]; at staff scope the return window is business-wide (any stylist at Oscar & Co counts); location scope keeps same-location semantics. Mirrors the split-window shape of client_retention_6m; only the base cohort is extra-restricted to clients new to the business.';


-- ---------------------------------------------------------------------
-- 2. private.debug_kpi_new_client_retention_6m
--    DROP + CREATE because the return shape changes to mirror
--    debug_kpi_client_retention_6m.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS private.debug_kpi_new_client_retention_6m(date, text, uuid, uuid);

CREATE FUNCTION private.debug_kpi_new_client_retention_6m(
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
  first_half_start      date,
  first_half_end        date,
  second_half_start     date,
  second_half_end       date,
  base_cohort_count     bigint,
  retained_count        bigint,
  row_count_in_window   bigint
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start      date := COALESCE(p_period_start, date_trunc('month', current_date)::date);
  v_period_end        date;
  v_mtd_through       date;
  v_is_current        boolean;
  v_scope             text := COALESCE(NULLIF(btrim(p_scope), ''), 'business');
  v_first_half_start  date;
  v_first_half_end    date;
  v_second_half_start date;
  v_second_half_end   date;
  v_base              bigint;
  v_retained          bigint;
  v_rows              bigint;
  v_value             numeric(18, 4);
  v_source            text;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION 'debug_kpi_new_client_retention_6m: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_new_client_retention_6m: invalid scope %', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_new_client_retention_6m: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_new_client_retention_6m: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  v_first_half_start  := (v_period_start - interval '5 months')::date;
  v_first_half_end    := ((v_period_start - interval '2 months')::date - 1);
  v_second_half_start := (v_period_start - interval '2 months')::date;
  v_second_half_end   := v_mtd_through;

  WITH normed AS (
    SELECT
      public.normalise_customer_name(e.customer_name) AS client_key,
      e.sale_date,
      e.location_id                                   AS loc_id,
      e.commission_owner_candidate_id                 AS owner_id
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_first_half_start AND v_second_half_end
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND public.normalise_customer_name(e.customer_name) <> ''
  ),
  first_half_candidates AS (
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_first_half_start AND v_first_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = p_location_id)
        OR (v_scope = 'staff'    AND owner_id = p_staff_member_id)
      )
  ),
  base_cohort AS (
    SELECT c.client_key
    FROM first_half_candidates c
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_first_half_start
        AND public.normalise_customer_name(e2.customer_name) = c.client_key
    )
  ),
  second_half_clients AS (
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_second_half_start AND v_second_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id = p_location_id)
        OR (v_scope = 'staff')
      )
  ),
  retained AS (
    SELECT b.client_key
    FROM base_cohort b
    JOIN second_half_clients s USING (client_key)
  ),
  window_rows AS (
    SELECT client_key
    FROM normed
    WHERE (
      v_scope = 'business'
      OR (v_scope = 'location' AND loc_id = p_location_id)
      OR (v_scope = 'staff')
    )
  ),
  agg AS (
    SELECT
      (SELECT COUNT(*) FROM base_cohort)  AS b_count,
      (SELECT COUNT(*) FROM retained)     AS r_count,
      (SELECT COUNT(*) FROM window_rows)  AS w_count
  )
  SELECT b_count, r_count, w_count
  INTO v_base, v_retained, v_rows
  FROM agg;

  v_value := CASE
               WHEN v_base > 0
                 THEN (v_retained::numeric / v_base::numeric)::numeric(18, 4)
               ELSE NULL
             END;

  v_source := format(
    'v_sales_transactions_enriched: retained / new-client base cohort; base=[%s,%s] (months 1-3, scoped, first-ever-seen before %s); return=[%s,%s] (months 4-6; business-wide for staff scope); non-internal; scope=%s',
    v_first_half_start, v_first_half_end,
    v_first_half_start,
    v_second_half_start, v_second_half_end,
    v_scope
  );

  RETURN QUERY
  SELECT
    'new_client_retention_6m'::text                           AS kpi_code,
    v_scope                                                   AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END     AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END AS staff_member_id,
    v_period_start                                            AS period_start,
    v_period_end                                              AS period_end,
    v_mtd_through                                             AS mtd_through,
    v_is_current                                              AS is_current_open_month,
    v_value                                                   AS value,
    v_retained::numeric(18, 4)                                AS value_numerator,
    v_base::numeric(18, 4)                                    AS value_denominator,
    v_source                                                  AS source,
    v_first_half_start                                        AS first_half_start,
    v_first_half_end                                          AS first_half_end,
    v_second_half_start                                       AS second_half_start,
    v_second_half_end                                         AS second_half_end,
    v_base                                                    AS base_cohort_count,
    v_retained                                                AS retained_count,
    v_rows                                                    AS row_count_in_window;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_new_client_retention_6m(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_new_client_retention_6m(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_new_client_retention_6m(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_new_client_retention_6m_live without the auth wrapper. Return shape parallels debug_kpi_client_retention_6m (first_half_start / _end, second_half_start / _end, base_cohort_count, retained_count, row_count_in_window). Drop when validation is complete.';


-- ---------------------------------------------------------------------
-- 3. public.get_kpi_new_client_retention_12m_live
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_new_client_retention_12m_live(
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
  v_period_start      date;
  v_period_end        date;
  v_mtd_through       date;
  v_is_current        boolean;
  v_scope             text;
  v_loc_id            uuid;
  v_staff_id          uuid;
  v_first_half_start  date;
  v_first_half_end    date;
  v_second_half_start date;
  v_second_half_end   date;
  v_base              bigint;
  v_retained          bigint;
  v_value             numeric(18, 4);
  v_source            text;
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_new_client_retention_12m_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  v_first_half_start  := (v_period_start - interval '11 months')::date;
  v_first_half_end    := ((v_period_start - interval '5 months')::date - 1);
  v_second_half_start := (v_period_start - interval '5 months')::date;
  v_second_half_end   := v_mtd_through;

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  WITH normed AS (
    SELECT
      public.normalise_customer_name(e.customer_name) AS client_key,
      e.sale_date,
      e.location_id                                   AS loc_id,
      e.commission_owner_candidate_id                 AS owner_id
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_first_half_start AND v_second_half_end
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND public.normalise_customer_name(e.customer_name) <> ''
  ),
  first_half_candidates AS (
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_first_half_start AND v_first_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = v_loc_id)
        OR (v_scope = 'staff'    AND owner_id = v_staff_id)
      )
  ),
  base_cohort AS (
    SELECT c.client_key
    FROM first_half_candidates c
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_first_half_start
        AND public.normalise_customer_name(e2.customer_name) = c.client_key
    )
  ),
  second_half_clients AS (
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_second_half_start AND v_second_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id = v_loc_id)
        OR (v_scope = 'staff')
      )
  ),
  retained AS (
    SELECT b.client_key
    FROM base_cohort b
    JOIN second_half_clients s USING (client_key)
  ),
  agg AS (
    SELECT
      (SELECT COUNT(*) FROM base_cohort) AS b_count,
      (SELECT COUNT(*) FROM retained)    AS r_count
  )
  SELECT b_count, r_count
  INTO v_base, v_retained
  FROM agg;

  v_value := CASE
               WHEN v_base > 0
                 THEN (v_retained::numeric / v_base::numeric)::numeric(18, 4)
               ELSE NULL
             END;

  v_source := format(
    'v_sales_transactions_enriched: retained / new-client base cohort; base=[%s,%s] (months 1-6, scoped, first-ever-seen before %s); return=[%s,%s] (months 7-12; business-wide for staff scope); non-internal; scope=%s',
    v_first_half_start, v_first_half_end,
    v_first_half_start,
    v_second_half_start, v_second_half_end,
    v_scope
  );

  RETURN QUERY
  SELECT
    'new_client_retention_12m'::text AS kpi_code,
    v_scope                          AS scope_type,
    v_loc_id                         AS location_id,
    v_staff_id                       AS staff_member_id,
    v_period_start                   AS period_start,
    v_period_end                     AS period_end,
    v_mtd_through                    AS mtd_through,
    v_is_current                     AS is_current_open_month,
    v_value                          AS value,
    v_retained::numeric(18, 4)       AS value_numerator,
    v_base::numeric(18, 4)           AS value_denominator,
    v_source                         AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_new_client_retention_12m_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_new_client_retention_12m_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_new_client_retention_12m_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_new_client_retention_12m_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_new_client_retention_12m_live(date, text, uuid, uuid) IS
'Live 12-month split-window new-client retention KPI. Base cohort = distinct normalise_customer_name who (a) first appear in the business within the first half [p-11m, p-5m-1d] and (b) were served at the requested scope in the first half. Retained = base-cohort clients seen in the second half [p-5m, MTD]; at staff scope the return window is business-wide (any stylist at Oscar & Co counts); location scope keeps same-location semantics. Mirrors the split-window shape of client_retention_12m; only the base cohort is extra-restricted to clients new to the business.';


-- ---------------------------------------------------------------------
-- 4. private.debug_kpi_new_client_retention_12m
--    DROP + CREATE because the return shape changes to mirror
--    debug_kpi_client_retention_12m.
-- ---------------------------------------------------------------------
DROP FUNCTION IF EXISTS private.debug_kpi_new_client_retention_12m(date, text, uuid, uuid);

CREATE FUNCTION private.debug_kpi_new_client_retention_12m(
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
  first_half_start      date,
  first_half_end        date,
  second_half_start     date,
  second_half_end       date,
  base_cohort_count     bigint,
  retained_count        bigint,
  row_count_in_window   bigint
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start      date := COALESCE(p_period_start, date_trunc('month', current_date)::date);
  v_period_end        date;
  v_mtd_through       date;
  v_is_current        boolean;
  v_scope             text := COALESCE(NULLIF(btrim(p_scope), ''), 'business');
  v_first_half_start  date;
  v_first_half_end    date;
  v_second_half_start date;
  v_second_half_end   date;
  v_base              bigint;
  v_retained          bigint;
  v_rows              bigint;
  v_value             numeric(18, 4);
  v_source            text;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION 'debug_kpi_new_client_retention_12m: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_new_client_retention_12m: invalid scope %', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_new_client_retention_12m: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_new_client_retention_12m: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  v_first_half_start  := (v_period_start - interval '11 months')::date;
  v_first_half_end    := ((v_period_start - interval '5 months')::date - 1);
  v_second_half_start := (v_period_start - interval '5 months')::date;
  v_second_half_end   := v_mtd_through;

  WITH normed AS (
    SELECT
      public.normalise_customer_name(e.customer_name) AS client_key,
      e.sale_date,
      e.location_id                                   AS loc_id,
      e.commission_owner_candidate_id                 AS owner_id
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_first_half_start AND v_second_half_end
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND public.normalise_customer_name(e.customer_name) <> ''
  ),
  first_half_candidates AS (
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_first_half_start AND v_first_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = p_location_id)
        OR (v_scope = 'staff'    AND owner_id = p_staff_member_id)
      )
  ),
  base_cohort AS (
    SELECT c.client_key
    FROM first_half_candidates c
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_first_half_start
        AND public.normalise_customer_name(e2.customer_name) = c.client_key
    )
  ),
  second_half_clients AS (
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_second_half_start AND v_second_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id = p_location_id)
        OR (v_scope = 'staff')
      )
  ),
  retained AS (
    SELECT b.client_key
    FROM base_cohort b
    JOIN second_half_clients s USING (client_key)
  ),
  window_rows AS (
    SELECT client_key
    FROM normed
    WHERE (
      v_scope = 'business'
      OR (v_scope = 'location' AND loc_id = p_location_id)
      OR (v_scope = 'staff')
    )
  ),
  agg AS (
    SELECT
      (SELECT COUNT(*) FROM base_cohort)  AS b_count,
      (SELECT COUNT(*) FROM retained)     AS r_count,
      (SELECT COUNT(*) FROM window_rows)  AS w_count
  )
  SELECT b_count, r_count, w_count
  INTO v_base, v_retained, v_rows
  FROM agg;

  v_value := CASE
               WHEN v_base > 0
                 THEN (v_retained::numeric / v_base::numeric)::numeric(18, 4)
               ELSE NULL
             END;

  v_source := format(
    'v_sales_transactions_enriched: retained / new-client base cohort; base=[%s,%s] (months 1-6, scoped, first-ever-seen before %s); return=[%s,%s] (months 7-12; business-wide for staff scope); non-internal; scope=%s',
    v_first_half_start, v_first_half_end,
    v_first_half_start,
    v_second_half_start, v_second_half_end,
    v_scope
  );

  RETURN QUERY
  SELECT
    'new_client_retention_12m'::text                          AS kpi_code,
    v_scope                                                   AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END     AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END AS staff_member_id,
    v_period_start                                            AS period_start,
    v_period_end                                              AS period_end,
    v_mtd_through                                             AS mtd_through,
    v_is_current                                              AS is_current_open_month,
    v_value                                                   AS value,
    v_retained::numeric(18, 4)                                AS value_numerator,
    v_base::numeric(18, 4)                                    AS value_denominator,
    v_source                                                  AS source,
    v_first_half_start                                        AS first_half_start,
    v_first_half_end                                          AS first_half_end,
    v_second_half_start                                       AS second_half_start,
    v_second_half_end                                         AS second_half_end,
    v_base                                                    AS base_cohort_count,
    v_retained                                                AS retained_count,
    v_rows                                                    AS row_count_in_window;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_new_client_retention_12m(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_new_client_retention_12m(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_new_client_retention_12m(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_new_client_retention_12m_live without the auth wrapper. Return shape parallels debug_kpi_client_retention_12m (first_half_start / _end, second_half_start / _end, base_cohort_count, retained_count, row_count_in_window). Drop when validation is complete.';
