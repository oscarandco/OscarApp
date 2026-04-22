-- =====================================================================
-- KPI snapshot dispatcher RPC: fetch multiple live KPIs in one call.
--
-- Purpose
-- -------
-- The app needs to fetch many KPI rows for a single (period, scope)
-- combination in one round-trip. Rather than add a new calculation
-- layer, the dispatcher simply UNION ALL-s the already-validated
-- per-KPI live RPCs and returns their rows in the LOCKED 12-column
-- KPI return shape. No KPI semantics are changed. No placeholder KPIs
-- are introduced. Only KPIs that currently have a validated live RPC
-- are included.
--
-- KPIs included (one row per KPI in the result set)
-- -------------------------------------------------
--   1.  revenue
--   2.  guests_per_month
--   3.  new_clients_per_month
--   4.  average_client_spend
--   5.  assistant_utilisation_ratio
--   6.  stylist_profitability
--   7.  client_frequency
--   8.  client_retention_6m
--   9.  client_retention_12m
--  10.  new_client_retention_6m
--  11.  new_client_retention_12m
--
-- Auth / access enforcement
-- -------------------------
-- The dispatcher follows the same pattern as every other live KPI RPC:
--   * SECURITY DEFINER + SET search_path = public, pg_temp.
--   * Delegates auth and scope validation to private.kpi_resolve_scope,
--     which raises SQLSTATE 28000 when auth.uid() is NULL and silently
--     collapses stylist/assistant callers to their own staff scope.
--   * Passes the RESOLVED scope values to each per-KPI RPC. Each
--     per-KPI RPC will re-run kpi_resolve_scope - this is idempotent
--     for an authenticated caller (same inputs -> same outputs) and
--     preserves the established auth contract on every per-KPI RPC
--     without new cross-function coupling.
--
-- Return shape
-- ------------
-- Exactly the locked 12-column KPI shape already used by every live
-- KPI RPC. No extra columns. No nested JSON. Order of KPIs in the
-- result set is stable (UNION ALL in declared order). Callers can
-- pivot on kpi_code client-side.
--
-- Error behaviour
-- ---------------
-- If any underlying per-KPI RPC raises, the dispatcher raises (the
-- whole snapshot fails as a unit). This is intentional for v1 - the
-- underlying RPCs share the same validation rules, so if one raises
-- they all would have raised. Partial-success masking would hide real
-- regressions.
--
-- Not in scope for this slice
-- ---------------------------
-- * No reads/writes to kpi_monthly_values (live-only dispatcher).
-- * No historical/finalised-month routing.
-- * No scope rollup merging (that belongs to a later aggregation layer).
-- * No placeholder / upcoming KPIs (utilisation, future_utilisation,
--   manual-input KPIs, etc.) - they are intentionally omitted until
--   they have their own validated live RPC.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_snapshot_live  (auth-enforced dispatcher)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_snapshot_live(
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
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_snapshot_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  -- Single resolve + auth assertion. Silently collapses stylist /
  -- assistant callers to their own staff scope.
  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  RETURN QUERY
    SELECT * FROM public.get_kpi_revenue_live                  (v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_guests_per_month_live         (v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_new_clients_per_month_live    (v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_average_client_spend_live     (v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_assistant_utilisation_ratio_live(v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_stylist_profitability_live    (v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_client_frequency_live         (v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_client_retention_6m_live      (v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_client_retention_12m_live     (v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_new_client_retention_6m_live  (v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_new_client_retention_12m_live (v_period_start, v_scope, v_loc_id, v_staff_id);
END;
$fn$;

ALTER FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid) IS
'Live KPI snapshot dispatcher. Returns one row per KPI (locked 12-column shape) for the requested period and scope by UNION ALL-ing the validated per-KPI live RPCs. Auth and scope resolution delegate to private.kpi_resolve_scope once; each per-KPI RPC also re-validates (idempotent). KPIs included: revenue, guests_per_month, new_clients_per_month, average_client_spend, assistant_utilisation_ratio, stylist_profitability, client_frequency, client_retention_6m, client_retention_12m, new_client_retention_6m, new_client_retention_12m.';


-- =====================================================================
-- 2. private.debug_kpi_snapshot  (validation only)
--
-- Mirror of the dispatcher that calls the per-KPI debug helpers
-- instead of the auth-enforced live RPCs so it can be exercised in the
-- Supabase SQL editor (auth.uid() is NULL there). Projects each debug
-- helper down to the 12 core KPI columns; the extra per-helper debug
-- columns are intentionally dropped here so the debug snapshot row
-- shape matches the live dispatcher row shape exactly.
-- =====================================================================

CREATE OR REPLACE FUNCTION private.debug_kpi_snapshot(
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
  source                text
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date := COALESCE(p_period_start, date_trunc('month', current_date)::date);
  v_scope        text := COALESCE(NULLIF(btrim(p_scope), ''), 'business');
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION 'debug_kpi_snapshot: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_snapshot: invalid scope %', v_scope USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_snapshot: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_snapshot: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_revenue(v_period_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_guests_per_month(v_period_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_new_clients_per_month(v_period_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_average_client_spend(v_period_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_assistant_utilisation_ratio(v_period_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_stylist_profitability(v_period_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_client_frequency(v_period_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_client_retention_6m(v_period_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_client_retention_12m(v_period_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_new_client_retention_6m(v_period_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_new_client_retention_12m(v_period_start, v_scope, p_location_id, p_staff_member_id) d;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_snapshot(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_snapshot(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_snapshot(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_snapshot_live that delegates to the per-KPI private.debug_kpi_* helpers (no auth wrapper). Projects each helper down to the locked 12-column KPI return shape so the snapshot row shape matches the live dispatcher. Drop when the v1 KPI validation phase is over.';
