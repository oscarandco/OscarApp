-- =====================================================================
-- client_frequency KPI: fix "column reference location_id is ambiguous"
--
-- Root cause
-- ----------
-- Both functions declare `location_id uuid` in their RETURNS TABLE
-- output signature, which makes `location_id` an implicit PL/pgSQL
-- variable visible inside the function body. The CTEs in migration
-- 20260501340000 also select and filter on a column literally named
-- `location_id`, so bare references such as
--
--   WHERE ... OR (v_scope = 'location' AND location_id = p_location_id)
--
-- become ambiguous with the output-column variable and the query fails
-- with "column reference location_id is ambiguous".
--
-- Fix
-- ---
-- Rename the CTE column from `location_id` to `loc_id` in both
-- functions. All other logic — reporting period semantics, trailing
-- 12m window, visit-unit definition, scope rules, numerator /
-- denominator, value-null-on-zero, return shape, auth — is unchanged.
-- This is a pure identifier-renaming patch inside two function bodies.
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

  -- CHANGED: the former `location_id` CTE column is renamed to `loc_id`
  -- throughout to avoid collision with the RETURNS TABLE output column
  -- of the same name. No other logic has changed.
  WITH normed AS (
    SELECT
      public.normalise_customer_name(e.customer_name) AS client_key,
      e.sale_date,
      e.location_id                                   AS loc_id,
      e.commission_owner_candidate_id                 AS owner_id,
      e.commission_owner_candidate_name               AS owner_name
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_window_start AND v_window_end
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  in_scope AS (
    SELECT client_key, sale_date, loc_id
    FROM normed
    WHERE client_key IS NOT NULL
      AND client_key <> ''
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = v_loc_id)
        OR (v_scope = 'staff'    AND owner_id = v_staff_id)
      )
  ),
  visits AS (
    SELECT DISTINCT client_key, sale_date, loc_id
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


-- ---------------------------------------------------------------------
-- 2. private.debug_kpi_client_frequency  (validation only)
-- ---------------------------------------------------------------------
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

  -- CHANGED: the former `location_id` CTE column is renamed to `loc_id`
  -- throughout to avoid collision with the RETURNS TABLE output column
  -- of the same name. No other logic has changed.
  WITH normed AS (
    SELECT
      public.normalise_customer_name(e.customer_name) AS client_key,
      e.sale_date,
      e.location_id                                   AS loc_id,
      e.commission_owner_candidate_id                 AS owner_id,
      e.commission_owner_candidate_name               AS owner_name
    FROM public.v_sales_transactions_enriched e
    WHERE e.sale_date BETWEEN v_window_start AND v_window_end
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  in_scope AS (
    SELECT client_key, sale_date, loc_id
    FROM normed
    WHERE client_key IS NOT NULL
      AND client_key <> ''
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND loc_id   = p_location_id)
        OR (v_scope = 'staff'    AND owner_id = p_staff_member_id)
      )
  ),
  visits AS (
    SELECT DISTINCT client_key, sale_date, loc_id
    FROM in_scope
  ),
  agg AS (
    SELECT
      (SELECT COUNT(*)                   FROM visits)   AS visit_count,
      (SELECT COUNT(DISTINCT client_key) FROM visits)   AS client_count,
      (SELECT COUNT(*)                   FROM in_scope) AS row_count_in_window
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
    'client_frequency'::text                                  AS kpi_code,
    v_scope                                                   AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END     AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END AS staff_member_id,
    v_period_start                                            AS period_start,
    v_period_end                                              AS period_end,
    v_mtd_through                                             AS mtd_through,
    v_is_current                                              AS is_current_open_month,
    v_value                                                   AS value,
    v_visits::numeric(18, 4)                                  AS value_numerator,
    v_clients::numeric(18, 4)                                 AS value_denominator,
    v_source                                                  AS source,
    v_window_start                                            AS window_start,
    v_window_end                                              AS window_end,
    v_visits                                                  AS visit_count,
    v_clients                                                 AS client_count,
    v_rows                                                    AS row_count_in_window;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_client_frequency(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_client_frequency(date, text, uuid, uuid) FROM PUBLIC;
