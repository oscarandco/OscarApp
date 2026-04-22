-- =====================================================================
-- DEBUG / VALIDATION ONLY.
--
-- Tiny pair of helpers that mirror the SQL bodies of the production
-- live KPI RPCs (public.get_kpi_revenue_live and
-- public.get_kpi_guests_per_month_live) but accept the scope inputs
-- explicitly and SKIP the auth.uid() / scope-resolution wrapper.
--
-- Why these exist
-- ----------------
-- The production RPCs go through private.kpi_resolve_scope, which
-- rejects callers where auth.uid() is NULL. The Supabase SQL editor
-- runs statements outside of an authenticated session, so the live
-- RPCs cannot be exercised there. These helpers let an operator
-- (or a CI smoke test running as service_role) verify the underlying
-- arithmetic against the same source view that production uses.
--
-- Why this is safe
-- ----------------
-- 1. They live in the `private` schema, which is not exposed via
--    PostgREST and has no grants to anon / authenticated. The Supabase
--    JS client cannot call them; only roles with USAGE on `private`
--    (postgres, service_role) can.
-- 2. They are SECURITY INVOKER. There is no privilege escalation:
--    a caller who can already read v_sales_transactions_enriched can
--    use these; everyone else gets "permission denied".
-- 3. The production RPCs are NOT modified. Their auth/scope checks
--    are unchanged. These helpers are a parallel, read-only mirror
--    intended for ad-hoc validation.
--
-- Removal
-- -------
-- Drop the two functions when no longer needed (see § "Removal" in
-- the chat note that accompanies this migration).
-- =====================================================================


-- ---------------------------------------------------------------------
-- Revenue (debug mirror of public.get_kpi_revenue_live)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.debug_kpi_revenue(
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
  v_total        numeric(18, 4);
  v_rows         bigint;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'debug_kpi_revenue: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION
      'debug_kpi_revenue: invalid scope %, expected business|location|staff', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_revenue: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_revenue: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT
    COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4),
    COUNT(*)
  INTO v_total, v_rows
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = v_period_start
    AND e.sale_date  <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND (
      v_scope = 'business'
      OR (v_scope = 'location' AND e.location_id = p_location_id)
      OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = p_staff_member_id)
    );

  RETURN QUERY
  SELECT
    'revenue'::text                                                AS kpi_code,
    v_scope                                                        AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END          AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END      AS staff_member_id,
    v_period_start                                                 AS period_start,
    v_period_end                                                   AS period_end,
    v_mtd_through                                                  AS mtd_through,
    v_is_current                                                   AS is_current_open_month,
    v_total                                                        AS value,
    v_total                                                        AS value_numerator,
    NULL::numeric(18, 4)                                           AS value_denominator,
    'public.v_sales_transactions_enriched (price_ex_gst)'::text    AS source,
    v_rows                                                         AS row_count;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_revenue(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_revenue(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_revenue(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_revenue_live without the auth wrapper. Same source view + filters; accepts scope inputs explicitly. Not exposed via PostgREST. Drop when validation is complete.';


-- ---------------------------------------------------------------------
-- Guests per month (debug mirror of public.get_kpi_guests_per_month_live)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.debug_kpi_guests_per_month(
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
  v_guests       numeric(18, 4);
  v_rows         bigint;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'debug_kpi_guests_per_month: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION
      'debug_kpi_guests_per_month: invalid scope %, expected business|location|staff', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_guests_per_month: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_guests_per_month: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT
    COALESCE(
      COUNT(DISTINCT public.normalise_customer_name(e.customer_name)),
      0
    )::numeric(18, 4),
    COUNT(*)
  INTO v_guests, v_rows
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = v_period_start
    AND e.sale_date  <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND public.normalise_customer_name(e.customer_name) IS NOT NULL
    AND (
      v_scope = 'business'
      OR (v_scope = 'location' AND e.location_id = p_location_id)
      OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = p_staff_member_id)
    );

  RETURN QUERY
  SELECT
    'guests_per_month'::text                                                                       AS kpi_code,
    v_scope                                                                                        AS scope_type,
    CASE WHEN v_scope = 'location' THEN p_location_id END                                          AS location_id,
    CASE WHEN v_scope = 'staff'    THEN p_staff_member_id END                                      AS staff_member_id,
    v_period_start                                                                                 AS period_start,
    v_period_end                                                                                   AS period_end,
    v_mtd_through                                                                                  AS mtd_through,
    v_is_current                                                                                   AS is_current_open_month,
    v_guests                                                                                       AS value,
    v_guests                                                                                       AS value_numerator,
    NULL::numeric(18, 4)                                                                           AS value_denominator,
    'distinct normalise_customer_name(customer_name) over v_sales_transactions_enriched'::text     AS source,
    v_rows                                                                                         AS row_count;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_guests_per_month(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_guests_per_month(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_guests_per_month(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_guests_per_month_live without the auth wrapper. Same source view + filters; accepts scope inputs explicitly. Not exposed via PostgREST. Drop when validation is complete.';
