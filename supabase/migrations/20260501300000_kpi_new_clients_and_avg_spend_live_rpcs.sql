-- =====================================================================
-- KPI live RPCs: new_clients_per_month + average_client_spend.
--
-- Mirrors the pattern set by 20260501280000 (revenue, guests):
--   * one auth-enforced public.* RPC per KPI (uses
--     private.kpi_resolve_scope for role/scope validation)
--   * one parallel private.debug_* helper (SECURITY INVOKER, not
--     exposed via PostgREST) for ad-hoc validation in the SQL editor
--
-- Source view: public.v_sales_transactions_enriched (same as the two
-- already-validated KPIs, so all four KPIs reconcile against the same
-- baseline). MTD-clipped to current_date for the open month.
--
-- Internal-line exclusion: rows where commission_owner_candidate_name
-- is 'internal' (case-insensitive) are excluded everywhere, exactly
-- as in revenue / guests_per_month.
--
-- new_clients_per_month
-- ---------------------
-- "First time ever seen" check is BUSINESS-WIDE (per
-- docs/KPI App Architecture.md §6.2 / §6.3: "no earlier appearance
-- in the full historical dataset", "first time ever seen in the full
-- dataset. Not rolling lookback."). The historical lookback is NOT
-- scope-restricted: a guest who first visited Takapuna in March is
-- not a new client to Orewa or to a stylist in April. The in-period
-- selection IS scope-restricted (business / location / staff) and
-- internal-excluded, exactly as for guests_per_month.
--
-- The historical check is also NOT internal-excluded: any prior
-- appearance — including against an "internal" attribution row —
-- disqualifies a guest from being "new". This is the safest
-- interpretation of "first time ever seen in the full dataset" and
-- avoids edge-case false positives where a name appeared earlier
-- only on internal rows.
--
-- Performance caveat: the "first time ever seen" lookup is a
-- correlated NOT EXISTS over v_sales_transactions_enriched against
-- public.normalise_customer_name(customer_name). At Oscar & Co's
-- current data volume (~10s of thousands of rows of history) this
-- runs in well under a second per call and does not need any new
-- indexes. If the historical dataset grows by 10x, the right next
-- step is an expression index on
-- public.sales_transactions(public.normalise_customer_name(customer_name))
-- — additive, IMMUTABLE-safe, and intentionally NOT added now to
-- keep this migration purely additive at the function layer.
--
-- average_client_spend
-- --------------------
-- Definition (locked, §3.2 / §6): revenue ÷ guests_per_month for the
-- same period and scope. The numerator and denominator are computed
-- in a single scan using the exact same WHERE clause as
-- get_kpi_revenue_live and get_kpi_guests_per_month_live, so this
-- KPI is *definitionally* equal to revenue ÷ guests_per_month at
-- any scope/period. Division by zero (no guests) returns NULL value
-- with non-NULL numerator/denominator so the caller can distinguish
-- "no data" from "zero spend".
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_new_clients_per_month_live
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_new_clients_per_month_live(
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
  v_new_clients  numeric(18, 4);
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_new_clients_per_month_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  WITH in_period_guests AS (
    SELECT DISTINCT public.normalise_customer_name(e.customer_name) AS norm_name
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = v_period_start
      AND e.sale_date  <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND e.location_id = v_loc_id)
        OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = v_staff_id)
      )
  )
  SELECT COUNT(*)::numeric(18, 4)
    INTO v_new_clients
  FROM in_period_guests g
  WHERE NOT EXISTS (
    SELECT 1
    FROM public.v_sales_transactions_enriched e2
    WHERE e2.sale_date < v_period_start
      AND public.normalise_customer_name(e2.customer_name) = g.norm_name
  );

  RETURN QUERY
  SELECT
    'new_clients_per_month'::text                                                                       AS kpi_code,
    v_scope                                                                                             AS scope_type,
    v_loc_id                                                                                            AS location_id,
    v_staff_id                                                                                          AS staff_member_id,
    v_period_start                                                                                      AS period_start,
    v_period_end                                                                                        AS period_end,
    v_mtd_through                                                                                       AS mtd_through,
    v_is_current                                                                                        AS is_current_open_month,
    v_new_clients                                                                                       AS value,
    v_new_clients                                                                                       AS value_numerator,
    NULL::numeric(18, 4)                                                                                AS value_denominator,
    'in-period guests over v_sales_transactions_enriched, NOT EXISTS prior history (business-wide)'::text AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_new_clients_per_month_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_new_clients_per_month_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_new_clients_per_month_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_new_clients_per_month_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_new_clients_per_month_live(date, text, uuid, uuid) IS
'Live new-clients-per-month KPI. In-period selection is scope-restricted; "first time ever seen" check is business-wide per KPI architecture doc §6.2/§6.3. Stylist/assistant callers are silently restricted to their own staff scope. Does not read or write kpi_monthly_values.';


-- ---------------------------------------------------------------------
-- 2. public.get_kpi_average_client_spend_live
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

  -- Single scan: numerator (revenue ex GST) and denominator (distinct
  -- normalised guests) computed against the identical WHERE clause
  -- so they match get_kpi_revenue_live / get_kpi_guests_per_month_live
  -- exactly at the same scope / period.
  SELECT
    COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4),
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
    'average_client_spend'::text                                                                                                       AS kpi_code,
    v_scope                                                                                                                            AS scope_type,
    v_loc_id                                                                                                                           AS location_id,
    v_staff_id                                                                                                                         AS staff_member_id,
    v_period_start                                                                                                                     AS period_start,
    v_period_end                                                                                                                       AS period_end,
    v_mtd_through                                                                                                                      AS mtd_through,
    v_is_current                                                                                                                       AS is_current_open_month,
    v_avg                                                                                                                              AS value,
    v_revenue                                                                                                                          AS value_numerator,
    v_guests                                                                                                                           AS value_denominator,
    'revenue (sum price_ex_gst) / distinct normalise_customer_name(customer_name); same filters as revenue + guests RPCs'::text        AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_average_client_spend_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_average_client_spend_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_average_client_spend_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_average_client_spend_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_average_client_spend_live(date, text, uuid, uuid) IS
'Live average client spend KPI = revenue / guests_per_month at the same scope/period. Returns value=NULL when guests=0 (numerator and denominator are still populated). Stylist/assistant callers are silently restricted to their own staff scope.';


-- =====================================================================
-- DEBUG / VALIDATION ONLY (private schema; not exposed via PostgREST).
--
-- Same pattern as 20260501290000_kpi_live_debug_validation_helpers.sql.
-- Mirrors the SQL bodies of the two new live RPCs but skips the auth
-- wrapper so the Supabase SQL editor (which has no auth.uid()) can
-- exercise the underlying logic directly. Drop these when the v1
-- KPI validation phase is over.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 3. private.debug_kpi_new_clients_per_month
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.debug_kpi_new_clients_per_month(
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
  in_period_guest_count bigint
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
  v_new_clients  numeric(18, 4);
  v_in_period    bigint;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION 'debug_kpi_new_clients_per_month: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_new_clients_per_month: invalid scope %', v_scope USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_new_clients_per_month: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_new_clients_per_month: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  WITH in_period_guests AS (
    SELECT DISTINCT public.normalise_customer_name(e.customer_name) AS norm_name
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = v_period_start
      AND e.sale_date  <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND e.location_id = p_location_id)
        OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = p_staff_member_id)
      )
  ),
  with_first_seen AS (
    SELECT g.norm_name,
           NOT EXISTS (
             SELECT 1 FROM public.v_sales_transactions_enriched e2
             WHERE e2.sale_date < v_period_start
               AND public.normalise_customer_name(e2.customer_name) = g.norm_name
           ) AS is_new
    FROM in_period_guests g
  )
  SELECT
    COUNT(*) FILTER (WHERE is_new)::numeric(18, 4),
    COUNT(*)
  INTO v_new_clients, v_in_period
  FROM with_first_seen;

  RETURN QUERY
  SELECT
    'new_clients_per_month'::text                                                                       AS kpi_code,
    v_scope                                                                                             AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END                                               AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END                                           AS staff_member_id,
    v_period_start                                                                                      AS period_start,
    v_period_end                                                                                        AS period_end,
    v_mtd_through                                                                                       AS mtd_through,
    v_is_current                                                                                        AS is_current_open_month,
    v_new_clients                                                                                       AS value,
    v_new_clients                                                                                       AS value_numerator,
    NULL::numeric(18, 4)                                                                                AS value_denominator,
    'in-period guests over v_sales_transactions_enriched, NOT EXISTS prior history (business-wide)'::text AS source,
    v_in_period                                                                                         AS in_period_guest_count;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_new_clients_per_month(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_new_clients_per_month(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_new_clients_per_month(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_new_clients_per_month_live without the auth wrapper. Adds in_period_guest_count for sanity-checking against guests_per_month. Drop when validation is complete.';


-- ---------------------------------------------------------------------
-- 4. private.debug_kpi_average_client_spend
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.debug_kpi_average_client_spend(
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
  v_revenue      numeric(18, 4);
  v_guests       numeric(18, 4);
  v_avg          numeric(18, 4);
  v_rows         bigint;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION 'debug_kpi_average_client_spend: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_average_client_spend: invalid scope %', v_scope USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_average_client_spend: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_average_client_spend: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT
    COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4),
    COUNT(DISTINCT public.normalise_customer_name(e.customer_name))::numeric(18, 4),
    COUNT(*)
  INTO v_revenue, v_guests, v_rows
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = v_period_start
    AND e.sale_date  <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND (
      v_scope = 'business'
      OR (v_scope = 'location' AND e.location_id = p_location_id)
      OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = p_staff_member_id)
    );

  v_avg := CASE
             WHEN v_guests > 0 THEN (v_revenue / v_guests)::numeric(18, 4)
             ELSE NULL
           END;

  RETURN QUERY
  SELECT
    'average_client_spend'::text                                                                                                       AS kpi_code,
    v_scope                                                                                                                            AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END                                                                              AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END                                                                          AS staff_member_id,
    v_period_start                                                                                                                     AS period_start,
    v_period_end                                                                                                                       AS period_end,
    v_mtd_through                                                                                                                      AS mtd_through,
    v_is_current                                                                                                                       AS is_current_open_month,
    v_avg                                                                                                                              AS value,
    v_revenue                                                                                                                          AS value_numerator,
    v_guests                                                                                                                           AS value_denominator,
    'revenue (sum price_ex_gst) / distinct normalise_customer_name(customer_name); same filters as revenue + guests RPCs'::text        AS source,
    v_rows                                                                                                                             AS row_count;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_average_client_spend(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_average_client_spend(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_average_client_spend(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_average_client_spend_live without the auth wrapper. Drop when validation is complete.';
