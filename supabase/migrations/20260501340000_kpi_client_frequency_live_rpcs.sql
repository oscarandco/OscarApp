-- =====================================================================
-- KPI live RPC + debug mirror: client_frequency
--
-- Locked definition (docs/KPI App Architecture.md):
--   client_frequency
--     = average visits per distinct client over the trailing 12 months
--       at the requested scope.
--
-- Source: public.v_sales_transactions_enriched. Same base used by the
-- six already-validated live KPIs. Non-internal rows only.
-- Customer identity: public.normalise_customer_name(customer_name).
--
-- Reporting period semantics
-- --------------------------
--   p_period_start is a calendar-month first-of-month date, EXACTLY
--   like every other live KPI (revenue, guests, etc.). period_end is
--   the last day of that calendar month. mtd_through is LEAST(period_end,
--   current_date), matching the existing KPIs' behaviour for the open
--   current month.
--
-- Trailing 12-month window (computation window for this KPI)
-- ----------------------------------------------------------
--   v_window_end   := mtd_through
--   v_window_start := (v_window_end + interval '1 day' - interval '12 months')::date
--
--   * Closed reporting month (e.g. 2026-03-01):
--       window = [2025-04-01, 2026-03-31] — exactly 12 calendar months
--       ending the last day of the reporting month.
--   * Current open reporting month (e.g. 2026-04-01 queried 2026-04-17):
--       window = [2025-04-18, 2026-04-17] — exactly 365 days ending
--       today, MTD-clipped consistent with revenue / guests / etc.
--
-- Visit unit (the thing being counted)
-- ------------------------------------
--   A "visit" is a distinct
--       (normalise_customer_name(customer_name), sale_date, location_id)
--   AFTER applying the scope filter.
--
--   * Collapses same-day multi-line transactions (service + retail rung
--     up together) into a single visit — without this, frequency is
--     wildly inflated.
--   * Correctly treats a client visiting two different salons the same
--     day as two visits at business scope.
--   * At staff scope the location-id grain remains: a stylist who
--     worked two locations the same day for the same client gets two
--     visits credited (rare; this is the accurate behaviour).
--
-- Scope behaviour
-- ---------------
--   business : all rows in window, all locations.
--   location : rows where location_id = v_loc_id.
--   staff    : rows where commission_owner_candidate_id = v_staff_id.
--              Stylist/assistant callers are silently restricted to
--              their own staff scope by private.kpi_resolve_scope.
--
-- Numerator / denominator / value
-- -------------------------------
--   value_numerator   = visit count (distinct visit units in scope).
--   value_denominator = distinct client count in scope.
--   value             = numerator / denominator, NULL when denominator
--                       is zero (numerator and denominator are still
--                       populated so the caller can distinguish "no
--                       data" from "no clients").
--
-- Return shape
-- ------------
-- Kept IDENTICAL to the other six live KPI RPCs (no extra columns),
-- so the future dispatcher RPC and any caller code can treat all
-- live KPIs uniformly. The trailing-window dates are encoded into
-- the `source` text. The debug helper adds explicit window_start /
-- window_end / visit_count / client_count / row_count_in_window
-- columns for inspection.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_client_frequency_live  (auth-enforced)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_client_frequency_live(
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
  v_window_start date;
  v_window_end   date;
  v_visits       bigint;
  v_clients      bigint;
  v_value        numeric(18, 4);
  v_source       text;
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_client_frequency_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  v_window_end   := v_mtd_through;
  v_window_start := (v_window_end + interval '1 day' - interval '12 months')::date;

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  WITH normed AS (
    SELECT
      public.normalise_customer_name(e.customer_name) AS client_key,
      e.sale_date,
      e.location_id,
      e.commission_owner_candidate_id,
      e.commission_owner_candidate_name
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_window_start AND v_window_end
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  in_scope AS (
    SELECT client_key, sale_date, location_id
    FROM normed
    WHERE client_key IS NOT NULL
      AND client_key <> ''
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND location_id = v_loc_id)
        OR (v_scope = 'staff'    AND commission_owner_candidate_id = v_staff_id)
      )
  ),
  visits AS (
    SELECT DISTINCT client_key, sale_date, location_id
    FROM in_scope
  )
  SELECT COUNT(*), COUNT(DISTINCT client_key)
  INTO v_visits, v_clients
  FROM visits;

  v_value := CASE
               WHEN v_clients > 0
                 THEN (v_visits::numeric / v_clients::numeric)::numeric(18, 4)
               ELSE NULL
             END;

  v_source := format(
    'v_sales_transactions_enriched: visits per distinct client over trailing 12m window [%s, %s]; visit unit = (normalise_customer_name, sale_date, location_id); non-internal',
    v_window_start, v_window_end
  );

  RETURN QUERY
  SELECT
    'client_frequency'::text  AS kpi_code,
    v_scope                   AS scope_type,
    v_loc_id                  AS location_id,
    v_staff_id                AS staff_member_id,
    v_period_start            AS period_start,
    v_period_end              AS period_end,
    v_mtd_through             AS mtd_through,
    v_is_current              AS is_current_open_month,
    v_value                   AS value,
    v_visits::numeric(18, 4)  AS value_numerator,
    v_clients::numeric(18, 4) AS value_denominator,
    v_source                  AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_client_frequency_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_client_frequency_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_client_frequency_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_client_frequency_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_client_frequency_live(date, text, uuid, uuid) IS
'Live client frequency KPI = visits / distinct clients over the trailing 12 months ending mtd_through. Visit unit = (normalise_customer_name, sale_date, location_id). Source: v_sales_transactions_enriched, non-internal. Stylist/assistant callers are silently restricted to their own staff scope.';


-- =====================================================================
-- 2. private.debug_kpi_client_frequency  (validation only)
--
-- Same SQL body as the live RPC, minus the auth wrapper. Adds explicit
-- window_start / window_end / visit_count / client_count /
-- row_count_in_window columns for sanity-checking. Not exposed via
-- PostgREST. Drop when the v1 KPI validation phase is over, alongside
-- the other debug_kpi_* helpers.
-- =====================================================================

CREATE OR REPLACE FUNCTION private.debug_kpi_client_frequency(
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
  window_start          date,
  window_end            date,
  visit_count           bigint,
  client_count          bigint,
  row_count_in_window   bigint
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
  v_window_start date;
  v_window_end   date;
  v_visits       bigint;
  v_clients      bigint;
  v_rows         bigint;
  v_value        numeric(18, 4);
  v_source       text;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION 'debug_kpi_client_frequency: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_client_frequency: invalid scope %', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_client_frequency: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_client_frequency: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  v_window_end   := v_mtd_through;
  v_window_start := (v_window_end + interval '1 day' - interval '12 months')::date;

  WITH normed AS (
    SELECT
      public.normalise_customer_name(e.customer_name) AS client_key,
      e.sale_date,
      e.location_id,
      e.commission_owner_candidate_id,
      e.commission_owner_candidate_name
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_window_start AND v_window_end
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  in_scope AS (
    SELECT client_key, sale_date, location_id
    FROM normed
    WHERE client_key IS NOT NULL
      AND client_key <> ''
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND location_id = p_location_id)
        OR (v_scope = 'staff'    AND commission_owner_candidate_id = p_staff_member_id)
      )
  ),
  visits AS (
    SELECT DISTINCT client_key, sale_date, location_id
    FROM in_scope
  ),
  agg AS (
    SELECT
      (SELECT COUNT(*)                FROM visits)   AS visit_count,
      (SELECT COUNT(DISTINCT client_key) FROM visits) AS client_count,
      (SELECT COUNT(*)                FROM in_scope) AS row_count_in_window
  )
  SELECT visit_count, client_count, row_count_in_window
  INTO v_visits, v_clients, v_rows
  FROM agg;

  v_value := CASE
               WHEN v_clients > 0
                 THEN (v_visits::numeric / v_clients::numeric)::numeric(18, 4)
               ELSE NULL
             END;

  v_source := format(
    'v_sales_transactions_enriched: visits per distinct client over trailing 12m window [%s, %s]; visit unit = (normalise_customer_name, sale_date, location_id); non-internal',
    v_window_start, v_window_end
  );

  RETURN QUERY
  SELECT
    'client_frequency'::text                              AS kpi_code,
    v_scope                                               AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END AS staff_member_id,
    v_period_start                                        AS period_start,
    v_period_end                                          AS period_end,
    v_mtd_through                                         AS mtd_through,
    v_is_current                                          AS is_current_open_month,
    v_value                                               AS value,
    v_visits::numeric(18, 4)                              AS value_numerator,
    v_clients::numeric(18, 4)                             AS value_denominator,
    v_source                                              AS source,
    v_window_start                                        AS window_start,
    v_window_end                                          AS window_end,
    v_visits                                              AS visit_count,
    v_clients                                             AS client_count,
    v_rows                                                AS row_count_in_window;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_client_frequency(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_client_frequency(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_client_frequency(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_client_frequency_live without the auth wrapper. Adds explicit window_start / window_end / visit_count / client_count / row_count_in_window for sanity-checking. Drop when validation is complete.';
