-- =====================================================================
-- KPI live RPC + debug mirror: client_retention_12m
--
-- Locked definition (docs/KPI App Architecture.md):
--   client_retention_12m = rolling 12-month split-window retention.
--
--   For a reporting month:
--     * base cohort = distinct clients seen in months 1-6 of the
--       trailing 12-month window.
--     * retained    = those cohort clients seen again in months 7-12
--       of the same window.
--     * value       = retained / base cohort, NULL when base cohort = 0.
--
-- Source and conventions carried over unchanged from client_retention_6m
-- (see 20260501370000_kpi_client_retention_6m_live_rpcs.sql):
--   * public.v_sales_transactions_enriched - same source as every
--     validated live KPI.
--   * public.normalise_customer_name(customer_name) - locked customer
--     identity. Empty / NULL normalisations excluded.
--   * Non-internal filter: commission_owner_candidate_name not 'internal'.
--   * CTE columns use `loc_id` / `owner_id` / `owner_name` to avoid
--     collision with RETURNS TABLE output variables (same fix as the
--     client_frequency ambiguity patches).
--
-- Window semantics (reporting month anchors month 12 of 12)
-- ---------------------------------------------------------
--   Let p = p_period_start (first-of-month).
--
--     first_half_start  = (p - interval '11 months')::date
--     first_half_end    = ((p - interval '5 months')::date - 1)
--     second_half_start = (p - interval '5 months')::date
--     second_half_end   = LEAST(period_end, current_date)   -- mtd_through
--
--   Example p = 2026-04-01:
--     first_half  = [2025-05-01, 2025-10-31]   (months 1-6:  May..Oct 2025)
--     second_half = [2025-11-01, 2026-04-30]   (months 7-12: Nov 2025..Apr 2026)
--
--   Closed-month behaviour:
--     second_half_end = period_end (complete 6-month return window).
--
--   Current-open-month behaviour:
--     second_half_end = current_date (MTD-clipped). The value is
--     "12m retention as of today MTD" and trends up through the month
--     as base-cohort clients return. This matches the MTD-clip
--     convention already locked for revenue / guests / client_frequency /
--     client_retention_6m. The base cohort window is unaffected by MTD
--     because it always ends ~5 months before the reporting month begins.
--
-- Scope of return (applied once, in-scope CTE, before the halves split)
-- ---------------------------------------------------------------------
--   business : any location, any stylist.
--   location : same location_id in BOTH halves.
--   staff    : same commission_owner_candidate_id in BOTH halves, i.e.
--              "did the same stylist see them again". Stylist/assistant
--              callers are silently restricted to their own staff scope
--              by private.kpi_resolve_scope.
--
-- Data-start edge
-- ---------------
-- If first_half_start predates the earliest data in
-- v_sales_transactions_enriched, the base cohort is truncated
-- accordingly and the value will reflect only clients actually
-- observable in the available data. The RPC does not raise - callers
-- can detect this by checking whether base_cohort_count looks
-- unusually low relative to guests_per_month for the same months.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_client_retention_12m_live  (auth-enforced)
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
      e.commission_owner_candidate_id                 AS owner_id,
      e.commission_owner_candidate_name               AS owner_name
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_first_half_start AND v_second_half_end
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  in_scope AS (
    SELECT client_key, sale_date
    FROM normed
    WHERE client_key IS NOT NULL
      AND client_key <> ''
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = v_loc_id)
        OR (v_scope = 'staff'    AND owner_id = v_staff_id)
      )
  ),
  base_cohort AS (
    SELECT DISTINCT client_key
    FROM in_scope
    WHERE sale_date BETWEEN v_first_half_start AND v_first_half_end
  ),
  second_half_clients AS (
    SELECT DISTINCT client_key
    FROM in_scope
    WHERE sale_date BETWEEN v_second_half_start AND v_second_half_end
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
    'v_sales_transactions_enriched: retained / base cohort; base=[%s,%s] (months 1-6); return=[%s,%s] (months 7-12); non-internal; scope of return = %s',
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

ALTER FUNCTION public.get_kpi_client_retention_12m_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_client_retention_12m_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_client_retention_12m_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_client_retention_12m_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_client_retention_12m_live(date, text, uuid, uuid) IS
'Live 12-month split-window client retention KPI. Base cohort = distinct normalise_customer_name in months 1-6 of the trailing 12-month window ending with the reporting month. Retained = those cohort clients seen again in months 7-12 at the same scope (business / same location / same stylist). Current open month is MTD-clipped for the second-half end date only.';


-- =====================================================================
-- 2. private.debug_kpi_client_retention_12m  (validation only)
--
-- Same SQL body as the live RPC, minus the auth wrapper. Adds explicit
-- window boundaries and the raw base / retained counts for
-- sanity-checking. Not exposed via PostgREST. Drop when the v1 KPI
-- validation phase is over, alongside the other debug_kpi_* helpers.
-- =====================================================================

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
      e.commission_owner_candidate_id                 AS owner_id,
      e.commission_owner_candidate_name               AS owner_name
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_first_half_start AND v_second_half_end
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  in_scope AS (
    SELECT client_key, sale_date
    FROM normed
    WHERE client_key IS NOT NULL
      AND client_key <> ''
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = p_location_id)
        OR (v_scope = 'staff'    AND owner_id = p_staff_member_id)
      )
  ),
  base_cohort AS (
    SELECT DISTINCT client_key
    FROM in_scope
    WHERE sale_date BETWEEN v_first_half_start AND v_first_half_end
  ),
  second_half_clients AS (
    SELECT DISTINCT client_key
    FROM in_scope
    WHERE sale_date BETWEEN v_second_half_start AND v_second_half_end
  ),
  retained AS (
    SELECT b.client_key
    FROM base_cohort b
    JOIN second_half_clients s USING (client_key)
  ),
  agg AS (
    SELECT
      (SELECT COUNT(*) FROM base_cohort) AS b_count,
      (SELECT COUNT(*) FROM retained)    AS r_count,
      (SELECT COUNT(*) FROM in_scope)    AS w_count
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
    'v_sales_transactions_enriched: retained / base cohort; base=[%s,%s] (months 1-6); return=[%s,%s] (months 7-12); non-internal; scope of return = %s',
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

ALTER FUNCTION private.debug_kpi_client_retention_12m(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_client_retention_12m(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_client_retention_12m(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_client_retention_12m_live without the auth wrapper. Adds explicit first_half / second_half boundaries and base_cohort_count / retained_count / row_count_in_window for sanity-checking. Drop when validation is complete.';
