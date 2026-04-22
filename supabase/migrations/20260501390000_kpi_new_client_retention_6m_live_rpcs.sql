-- =====================================================================
-- KPI live RPC + debug mirror: new_client_retention_6m
--
-- Locked definition (docs/KPI App Architecture.md):
--   new_client_retention_6m = true acquisition-cohort retention.
--
--   For a reporting month (= base/acquisition month):
--     * cohort   = clients whose FIRST-EVER appearance in the business
--                  dataset falls in the base month AND who were seen
--                  at the requested scope in the base month.
--     * retained = those cohort clients who return AT THE REQUESTED
--                  SCOPE within the next 6 calendar months after the
--                  base month.
--     * value    = retained / cohort, NULL when cohort = 0.
--
-- Identity rules (unchanged, locked):
--   * Customer identity via public.normalise_customer_name(customer_name).
--   * "New client" = first time ever seen in the full business dataset
--     (business-wide NOT EXISTS against prior history). This matches the
--     rule used by get_kpi_new_clients_per_month_live and does NOT
--     filter the historical check by internal/scope — any prior
--     appearance disqualifies the client from being "new".
--
-- Source: public.v_sales_transactions_enriched (same as every other
-- validated live KPI).
--
-- Internal-line exclusion:
--   * Base-month eligibility (did the client visit at requested scope
--     in the base month) excludes internal rows, matching the in-period
--     selection rule from new_clients_per_month / guests_per_month.
--   * Retention observation window also excludes internal rows.
--   * The "first ever seen" history check itself is NOT internal-excluded
--     (any prior appearance, even internal, disqualifies the client),
--     matching the already-locked new_clients_per_month behaviour.
--
-- Window semantics
-- ----------------
--   Let p = p_period_start (first-of-month). Reporting month == base month.
--
--     base_month_start      = p
--     base_month_end_full   = (p + interval '1 month - 1 day')::date
--     base_month_end_obs    = LEAST(base_month_end_full, current_date)  -- MTD-clipped when current open month
--
--     return_window_start   = (p + interval '1 month')::date                    -- day after base_month_end_full
--     return_window_end_full = (p + interval '7 months' - interval '1 day')::date   -- exactly 6 calendar months after base_month_end_full
--     return_window_end_obs  = LEAST(return_window_end_full, current_date)
--
--   Example p = 2025-06-01:
--     base_month    = [2025-06-01, 2025-06-30]
--     return_window = [2025-07-01, 2025-12-31]   (6 months: Jul..Dec 2025)
--
--   Current open month and very recent months
--   -----------------------------------------
--   * Base-month acquisition: if the reporting month is the current
--     open month, the cohort is MTD-clipped - clients whose first-ever
--     business appearance is between p and current_date. Same rule as
--     new_clients_per_month. The cohort will keep growing through the
--     remainder of the month.
--   * Return-window observation: clipped to current_date. If
--     return_window_end_obs < return_window_start (i.e. the return
--     window has not started yet, typical for the current open month
--     and the immediately-preceding month until day 1 of the month after),
--     retained = 0 by construction. The value then reflects "retention
--     observed so far" and will climb as the return window matures.
--   * Maturity signal: the live RPC preserves the locked 12-column KPI
--     return shape (no extra columns). Maturity is encoded in the
--     `source` text ("mature=true|false") and exposed explicitly by the
--     debug helper via `is_return_window_complete`. Dispatcher/UI
--     consumers can derive maturity deterministically from period_start
--     vs current_date if needed.
--
--   Reporting month anchors the START of the retention window. The
--   return window runs strictly AFTER the base month and is 6 full
--   calendar months long when mature.
--
-- Scope (applied consistently to cohort eligibility and retention observation)
-- ---------------------------------------------------------------------------
--   business : cohort = new clients seen anywhere in the business in
--              the base month; retained = any visit in the business in
--              the return window.
--   location : cohort = new clients seen at the requested location in
--              the base month; retained = any visit at the SAME location
--              in the return window.
--   staff    : cohort = new clients seen by the requested stylist in
--              the base month; retained = any visit with the SAME
--              stylist (commission_owner_candidate_id) in the return
--              window. Stylist/assistant callers are silently restricted
--              to their own staff scope by private.kpi_resolve_scope.
--
-- Performance caveat: same as new_clients_per_month - the "first ever
-- seen" check is a business-wide NOT EXISTS over
-- v_sales_transactions_enriched against normalise_customer_name. At
-- current data volume this runs well under a second. If the historical
-- dataset grows by ~10x, the right additive next step is an expression
-- index on public.sales_transactions(normalise_customer_name(customer_name))
-- - intentionally NOT added here to keep this migration purely additive.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_new_client_retention_6m_live  (auth-enforced)
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
  v_return_start      date;
  v_return_end_full   date;
  v_return_end_obs    date;
  v_rw_complete       boolean;
  v_cohort            bigint;
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

  v_return_start    := (v_period_start + interval '1 month')::date;
  v_return_end_full := (v_period_start + interval '7 months' - interval '1 day')::date;
  v_return_end_obs  := LEAST(v_return_end_full, current_date);
  v_rw_complete     := (current_date >= v_return_end_full);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  -- Cohort: clients first-ever-seen in the base month at the requested
  -- scope. "First ever seen" is a business-wide NOT EXISTS (unchanged
  -- locked rule from new_clients_per_month).
  WITH in_period_guests AS (
    SELECT DISTINCT public.normalise_customer_name(e.customer_name) AS client_key
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = v_period_start
      AND e.sale_date  <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND public.normalise_customer_name(e.customer_name) <> ''
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND e.location_id                     = v_loc_id)
        OR (v_scope = 'staff'    AND e.commission_owner_candidate_id   = v_staff_id)
      )
  ),
  cohort AS (
    SELECT g.client_key
    FROM in_period_guests g
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_period_start
        AND public.normalise_customer_name(e2.customer_name) = g.client_key
    )
  ),
  return_visits AS (
    SELECT DISTINCT public.normalise_customer_name(e.customer_name) AS client_key
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_return_start AND v_return_end_obs
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND public.normalise_customer_name(e.customer_name) <> ''
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND e.location_id                     = v_loc_id)
        OR (v_scope = 'staff'    AND e.commission_owner_candidate_id   = v_staff_id)
      )
  ),
  agg AS (
    SELECT
      (SELECT COUNT(*) FROM cohort) AS c_count,
      (SELECT COUNT(*)
         FROM cohort c
         JOIN return_visits r USING (client_key))
        AS r_count
  )
  SELECT c_count,
         CASE WHEN v_return_end_obs < v_return_start THEN 0 ELSE r_count END
  INTO v_cohort, v_retained
  FROM agg;

  v_value := CASE
               WHEN v_cohort > 0
                 THEN (v_retained::numeric / v_cohort::numeric)::numeric(18, 4)
               ELSE NULL
             END;

  v_source := format(
    'v_sales_transactions_enriched: retained / new-client cohort; cohort=first-ever-seen in base=[%s,%s] (MTD-clipped); return=[%s,%s] (full end %s, mature=%s); non-internal; scope = %s',
    v_period_start, v_mtd_through,
    v_return_start, v_return_end_obs,
    v_return_end_full,
    v_rw_complete,
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
    v_cohort::numeric(18, 4)        AS value_denominator,
    v_source                        AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_new_client_retention_6m_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_new_client_retention_6m_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_new_client_retention_6m_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_new_client_retention_6m_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_new_client_retention_6m_live(date, text, uuid, uuid) IS
'Live 6-month new-client acquisition-cohort retention KPI. Cohort = clients whose first-ever business appearance is in the base/reporting month AND who were seen at the requested scope (business / same location / same stylist). Retained = cohort clients who return at the same scope in the 6 calendar months AFTER the base month. Return window is MTD-clipped; maturity is encoded in the source text and exposed explicitly by the debug helper (is_return_window_complete). Live RPC preserves the locked 12-column KPI return shape. "First ever seen" check is business-wide per the locked new-client rule.';


-- =====================================================================
-- 2. private.debug_kpi_new_client_retention_6m  (validation only)
-- =====================================================================

CREATE OR REPLACE FUNCTION private.debug_kpi_new_client_retention_6m(
  p_period_start    date,
  p_scope           text DEFAULT 'business',
  p_location_id     uuid DEFAULT NULL,
  p_staff_member_id uuid DEFAULT NULL
)
RETURNS TABLE (
  kpi_code                    text,
  scope_type                  text,
  location_id                 uuid,
  staff_member_id             uuid,
  period_start                date,
  period_end                  date,
  mtd_through                 date,
  is_current_open_month       boolean,
  is_return_window_complete   boolean,
  value                       numeric(18, 4),
  value_numerator             numeric(18, 4),
  value_denominator           numeric(18, 4),
  source                      text,
  base_month_start            date,
  base_month_end_observed     date,
  return_window_start         date,
  return_window_end_full      date,
  return_window_end_observed  date,
  cohort_count                bigint,
  retained_count              bigint,
  in_period_guest_count       bigint
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
  v_return_start      date;
  v_return_end_full   date;
  v_return_end_obs    date;
  v_rw_complete       boolean;
  v_cohort            bigint;
  v_retained          bigint;
  v_in_period         bigint;
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

  v_return_start    := (v_period_start + interval '1 month')::date;
  v_return_end_full := (v_period_start + interval '7 months' - interval '1 day')::date;
  v_return_end_obs  := LEAST(v_return_end_full, current_date);
  v_rw_complete     := (current_date >= v_return_end_full);

  WITH in_period_guests AS (
    SELECT DISTINCT public.normalise_customer_name(e.customer_name) AS client_key
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = v_period_start
      AND e.sale_date  <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND public.normalise_customer_name(e.customer_name) <> ''
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND e.location_id                     = p_location_id)
        OR (v_scope = 'staff'    AND e.commission_owner_candidate_id   = p_staff_member_id)
      )
  ),
  cohort AS (
    SELECT g.client_key
    FROM in_period_guests g
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_period_start
        AND public.normalise_customer_name(e2.customer_name) = g.client_key
    )
  ),
  return_visits AS (
    SELECT DISTINCT public.normalise_customer_name(e.customer_name) AS client_key
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_return_start AND v_return_end_obs
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND public.normalise_customer_name(e.customer_name) <> ''
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND e.location_id                     = p_location_id)
        OR (v_scope = 'staff'    AND e.commission_owner_candidate_id   = p_staff_member_id)
      )
  ),
  agg AS (
    SELECT
      (SELECT COUNT(*) FROM in_period_guests) AS g_count,
      (SELECT COUNT(*) FROM cohort)           AS c_count,
      (SELECT COUNT(*)
         FROM cohort c
         JOIN return_visits r USING (client_key))
                                              AS r_count
  )
  SELECT g_count, c_count,
         CASE WHEN v_return_end_obs < v_return_start THEN 0 ELSE r_count END
  INTO v_in_period, v_cohort, v_retained
  FROM agg;

  v_value := CASE
               WHEN v_cohort > 0
                 THEN (v_retained::numeric / v_cohort::numeric)::numeric(18, 4)
               ELSE NULL
             END;

  v_source := format(
    'v_sales_transactions_enriched: retained / new-client cohort; cohort=first-ever-seen in base=[%s,%s] (MTD-clipped); return=[%s,%s] (full end %s); non-internal; scope = %s',
    v_period_start, v_mtd_through,
    v_return_start, v_return_end_obs,
    v_return_end_full,
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
    v_rw_complete                                             AS is_return_window_complete,
    v_value                                                   AS value,
    v_retained::numeric(18, 4)                                AS value_numerator,
    v_cohort::numeric(18, 4)                                  AS value_denominator,
    v_source                                                  AS source,
    v_period_start                                            AS base_month_start,
    v_mtd_through                                             AS base_month_end_observed,
    v_return_start                                            AS return_window_start,
    v_return_end_full                                         AS return_window_end_full,
    v_return_end_obs                                          AS return_window_end_observed,
    v_cohort                                                  AS cohort_count,
    v_retained                                                AS retained_count,
    v_in_period                                               AS in_period_guest_count;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_new_client_retention_6m(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_new_client_retention_6m(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_new_client_retention_6m(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_new_client_retention_6m_live without the auth wrapper. Adds base/return window boundaries, cohort_count, retained_count, in_period_guest_count (= guests_per_month-style count at same scope) so the cohort can be reconciled against new_clients_per_month. Drop when validation is complete.';
