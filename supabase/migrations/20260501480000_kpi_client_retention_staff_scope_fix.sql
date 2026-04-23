-- =====================================================================
-- KPI fix: client_retention_6m / client_retention_12m staff-scope rule
--
-- Problem
-- -------
-- The previous implementation applied the scope filter in a single
-- `in_scope` CTE before the halves were split, so at staff scope the
-- second-half membership required the client to be attributed to the
-- same stylist. That contradicts the locked business rule:
--
--   staff/self scope
--     base cohort = clients served by that stylist in the first half
--     retained    = those same clients seen by ANYONE at Oscar & Co
--                   in the second half
--
-- Fix
-- ---
-- Split the scope filter into two stages:
--   * base_cohort  : full scope filter (business / same location /
--                    same stylist) — unchanged semantics.
--   * second_half  : business → no filter
--                    location → same location_id (unchanged)
--                    staff    → NO staff filter (any stylist counts
--                               as a return — new rule).
--
-- Business and location behaviour are preserved. Only staff scope
-- changes, and only the second-half side changes — the base cohort
-- still requires the stylist attribution in the first half.
--
-- Scope of this fix
-- -----------------
-- Applies to client_retention_6m and client_retention_12m only
-- (public + private debug mirrors). new_client_retention_6m / 12m
-- are intentionally not touched.
--
-- RPC return shape
-- ----------------
-- Both public RPCs keep the locked 12-column shape; the debug mirrors
-- keep their extended diagnostic columns. No frontend contract change.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_client_retention_6m_live
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_client_retention_6m_live(
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
      'get_kpi_client_retention_6m_live: p_period_start must be the 1st of a month, got %',
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
  base_cohort AS (
    -- Base cohort applies the FULL scope filter (including staff).
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_first_half_start AND v_first_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = v_loc_id)
        OR (v_scope = 'staff'    AND owner_id = v_staff_id)
      )
  ),
  second_half_clients AS (
    -- Second-half membership: business → any row, location → same
    -- location, staff → any row at Oscar & Co (NEW RULE: retained
    -- means the cohort client returned anywhere in the business,
    -- not just to the same stylist).
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
    'v_sales_transactions_enriched: retained / base cohort; base=[%s,%s] (months 1-3, scoped); return=[%s,%s] (months 4-6; business-wide for staff scope); non-internal; scope=%s',
    v_first_half_start, v_first_half_end,
    v_second_half_start, v_second_half_end,
    v_scope
  );

  RETURN QUERY
  SELECT
    'client_retention_6m'::text  AS kpi_code,
    v_scope                      AS scope_type,
    v_loc_id                     AS location_id,
    v_staff_id                   AS staff_member_id,
    v_period_start               AS period_start,
    v_period_end                 AS period_end,
    v_mtd_through                AS mtd_through,
    v_is_current                 AS is_current_open_month,
    v_value                      AS value,
    v_retained::numeric(18, 4)   AS value_numerator,
    v_base::numeric(18, 4)       AS value_denominator,
    v_source                     AS source;
END;
$fn$;

COMMENT ON FUNCTION public.get_kpi_client_retention_6m_live(date, text, uuid, uuid) IS
'Live 6-month split-window client retention KPI. Base cohort = distinct normalise_customer_name in months 1-3 of the trailing 6-month window at the requested scope. Retained = base-cohort clients seen in months 4-6; at staff scope the return window is business-wide (any stylist at Oscar & Co counts). Location scope keeps same-location semantics in both halves. Current open month is MTD-clipped for the second-half end only.';


-- ---------------------------------------------------------------------
-- 2. private.debug_kpi_client_retention_6m
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.debug_kpi_client_retention_6m(
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
    RAISE EXCEPTION 'debug_kpi_client_retention_6m: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_client_retention_6m: invalid scope %', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_client_retention_6m: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_client_retention_6m: staff scope requires p_staff_member_id'
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
  base_cohort AS (
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_first_half_start AND v_first_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = p_location_id)
        OR (v_scope = 'staff'    AND owner_id = p_staff_member_id)
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
    'v_sales_transactions_enriched: retained / base cohort; base=[%s,%s] (months 1-3, scoped); return=[%s,%s] (months 4-6; business-wide for staff scope); non-internal; scope=%s',
    v_first_half_start, v_first_half_end,
    v_second_half_start, v_second_half_end,
    v_scope
  );

  RETURN QUERY
  SELECT
    'client_retention_6m'::text                               AS kpi_code,
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


-- ---------------------------------------------------------------------
-- 3. public.get_kpi_client_retention_12m_live
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_client_retention_12m_live(
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
      'get_kpi_client_retention_12m_live: p_period_start must be the 1st of a month, got %',
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
  base_cohort AS (
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_first_half_start AND v_first_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = v_loc_id)
        OR (v_scope = 'staff'    AND owner_id = v_staff_id)
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
    'v_sales_transactions_enriched: retained / base cohort; base=[%s,%s] (months 1-6, scoped); return=[%s,%s] (months 7-12; business-wide for staff scope); non-internal; scope=%s',
    v_first_half_start, v_first_half_end,
    v_second_half_start, v_second_half_end,
    v_scope
  );

  RETURN QUERY
  SELECT
    'client_retention_12m'::text AS kpi_code,
    v_scope                      AS scope_type,
    v_loc_id                     AS location_id,
    v_staff_id                   AS staff_member_id,
    v_period_start               AS period_start,
    v_period_end                 AS period_end,
    v_mtd_through                AS mtd_through,
    v_is_current                 AS is_current_open_month,
    v_value                      AS value,
    v_retained::numeric(18, 4)   AS value_numerator,
    v_base::numeric(18, 4)       AS value_denominator,
    v_source                     AS source;
END;
$fn$;

COMMENT ON FUNCTION public.get_kpi_client_retention_12m_live(date, text, uuid, uuid) IS
'Live 12-month split-window client retention KPI. Base cohort = distinct normalise_customer_name in months 1-6 of the trailing 12-month window at the requested scope. Retained = base-cohort clients seen in months 7-12; at staff scope the return window is business-wide (any stylist at Oscar & Co counts). Location scope keeps same-location semantics in both halves. Current open month is MTD-clipped for the second-half end only.';


-- ---------------------------------------------------------------------
-- 4. private.debug_kpi_client_retention_12m
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.debug_kpi_client_retention_12m(
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
    RAISE EXCEPTION 'debug_kpi_client_retention_12m: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_client_retention_12m: invalid scope %', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_client_retention_12m: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_client_retention_12m: staff scope requires p_staff_member_id'
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
  base_cohort AS (
    SELECT DISTINCT client_key
    FROM normed
    WHERE sale_date BETWEEN v_first_half_start AND v_first_half_end
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = p_location_id)
        OR (v_scope = 'staff'    AND owner_id = p_staff_member_id)
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
    'v_sales_transactions_enriched: retained / base cohort; base=[%s,%s] (months 1-6, scoped); return=[%s,%s] (months 7-12; business-wide for staff scope); non-internal; scope=%s',
    v_first_half_start, v_first_half_end,
    v_second_half_start, v_second_half_end,
    v_scope
  );

  RETURN QUERY
  SELECT
    'client_retention_12m'::text                              AS kpi_code,
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
