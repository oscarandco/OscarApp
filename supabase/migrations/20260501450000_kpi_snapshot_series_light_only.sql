-- =====================================================================
-- KPI trends — restrict series to the lightweight KPI subset.
--
-- Why this migration exists
-- -------------------------
-- The previous series implementation
-- (20260501440000_kpi_snapshot_series_live_perf.sql) still timed out
-- at production data volumes because the per-KPI debug helpers for
-- retention / frequency are intrinsically heavy:
--
--   * new_client_retention_6m  /  new_client_retention_12m
--       business-wide "first ever seen" NOT EXISTS scans over the
--       full v_sales_transactions_enriched history, per month.
--   * client_retention_6m      /  client_retention_12m
--       6- and 12-month rolling windows with half/half split joins,
--       per month.
--   * client_frequency
--       all-client visit-count aggregate over a 6-month window,
--       per month.
--
-- Each of those costs is unchanged (per locked KPI math) and is
-- simply too expensive to multiply by month-count on demand.
--
-- Decision for this slice
-- -----------------------
-- Trends keeps the existing architecture but only covers the six
-- lightweight KPIs whose debug helpers are bounded single-month
-- aggregates over the same scope/month window:
--
--   revenue
--   guests_per_month
--   new_clients_per_month
--   average_client_spend
--   assistant_utilisation_ratio
--   stylist_profitability
--
-- The five heavy KPIs above are intentionally omitted from trends
-- for now. Snapshot continues to cover all 11 KPIs unchanged; this
-- migration does not touch public.get_kpi_snapshot_live or any
-- per-KPI live / debug function.
--
-- Correctness
-- -----------
-- No KPI math changes. The 6 retained UNION branches are an exact
-- subset of the previous migration's UNION and each branch is
-- identical in SQL to its previous form (same LATERAL per-month call
-- into the same per-KPI debug helper). The 12-column output shape
-- and ordering are preserved. Public signature, grants, and comment
-- target are preserved so the frontend trends hook needs no change.
--
-- When durable monthly actuals exist
-- ----------------------------------
-- When the hybrid-actuals `kpi_actuals_monthly` table lands, the
-- series RPC can be widened back to all KPIs by reading from that
-- table for closed months and only computing the current open month
-- live. That is an additive future change; this slice is deliberately
-- the smallest safe step to ship trends now.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_snapshot_series_live  (lightweight subset)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_snapshot_series_live(
  p_month_start     date    DEFAULT NULL,
  p_month_count     integer DEFAULT 12,
  p_scope           text    DEFAULT 'business',
  p_location_id     uuid    DEFAULT NULL,
  p_staff_member_id uuid    DEFAULT NULL
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
  v_anchor   date;
  v_count    integer;
  v_scope    text;
  v_loc_id   uuid;
  v_staff_id uuid;
BEGIN
  v_anchor := COALESCE(p_month_start, date_trunc('month', current_date)::date);

  IF v_anchor <> date_trunc('month', v_anchor)::date THEN
    RAISE EXCEPTION
      'get_kpi_snapshot_series_live: p_month_start must be the 1st of a month, got %',
      v_anchor
      USING ERRCODE = '22023';
  END IF;

  v_count := COALESCE(p_month_count, 12);
  IF v_count < 1 OR v_count > 36 THEN
    RAISE EXCEPTION
      'get_kpi_snapshot_series_live: p_month_count must be between 1 and 36, got %',
      v_count
      USING ERRCODE = '22023';
  END IF;

  -- Single auth + scope resolution for the entire series.
  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  RETURN QUERY
  WITH months AS (
    SELECT (v_anchor - (g.i * interval '1 month'))::date AS m_start
    FROM generate_series(0, v_count - 1) AS g(i)
  ),
  rows AS (
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_revenue(m.m_start, v_scope, v_loc_id, v_staff_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_guests_per_month(m.m_start, v_scope, v_loc_id, v_staff_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_new_clients_per_month(m.m_start, v_scope, v_loc_id, v_staff_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_average_client_spend(m.m_start, v_scope, v_loc_id, v_staff_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_assistant_utilisation_ratio(m.m_start, v_scope, v_loc_id, v_staff_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_stylist_profitability(m.m_start, v_scope, v_loc_id, v_staff_id) d
  )
  SELECT r.kpi_code, r.scope_type, r.location_id, r.staff_member_id,
         r.period_start, r.period_end, r.mtd_through, r.is_current_open_month,
         r.value, r.value_numerator, r.value_denominator, r.source
  FROM rows r
  ORDER BY r.period_start ASC, r.kpi_code ASC;
END;
$fn$;

ALTER FUNCTION public.get_kpi_snapshot_series_live(date, integer, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_snapshot_series_live(date, integer, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_snapshot_series_live(date, integer, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_snapshot_series_live(date, integer, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_snapshot_series_live(date, integer, text, uuid, uuid) IS
'Monthly KPI trends. Resolves auth + scope ONCE via private.kpi_resolve_scope, then UNION ALLs the six LIGHTWEIGHT per-KPI debug helpers (private.debug_kpi_revenue, _guests_per_month, _new_clients_per_month, _average_client_spend, _assistant_utilisation_ratio, _stylist_profitability) LATERAL-joined to a generate_series of month-start anchors. Retention / frequency KPIs are intentionally excluded from trends until monthly actuals are materialised; snapshot still covers all KPIs via public.get_kpi_snapshot_live. Locked 12-column shape, ordered (period_start ASC, kpi_code ASC). p_month_count bounded 1..36.';


-- ---------------------------------------------------------------------
-- 2. private.debug_kpi_snapshot_series  (validation mirror, same subset)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.debug_kpi_snapshot_series(
  p_month_start     date,
  p_month_count     integer DEFAULT 12,
  p_scope           text    DEFAULT 'business',
  p_location_id     uuid    DEFAULT NULL,
  p_staff_member_id uuid    DEFAULT NULL
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
  v_anchor date    := COALESCE(p_month_start, date_trunc('month', current_date)::date);
  v_count  integer := COALESCE(p_month_count, 12);
  v_scope  text    := COALESCE(NULLIF(btrim(p_scope), ''), 'business');
BEGIN
  IF v_anchor <> date_trunc('month', v_anchor)::date THEN
    RAISE EXCEPTION
      'debug_kpi_snapshot_series: p_month_start must be the 1st of a month, got %',
      v_anchor
      USING ERRCODE = '22023';
  END IF;
  IF v_count < 1 OR v_count > 36 THEN
    RAISE EXCEPTION
      'debug_kpi_snapshot_series: p_month_count must be between 1 and 36, got %',
      v_count
      USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_snapshot_series: invalid scope %', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_snapshot_series: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_snapshot_series: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH months AS (
    SELECT (v_anchor - (g.i * interval '1 month'))::date AS m_start
    FROM generate_series(0, v_count - 1) AS g(i)
  ),
  rows AS (
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_revenue(m.m_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_guests_per_month(m.m_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_new_clients_per_month(m.m_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_average_client_spend(m.m_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_assistant_utilisation_ratio(m.m_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_stylist_profitability(m.m_start, v_scope, p_location_id, p_staff_member_id) d
  )
  SELECT r.kpi_code, r.scope_type, r.location_id, r.staff_member_id,
         r.period_start, r.period_end, r.mtd_through, r.is_current_open_month,
         r.value, r.value_numerator, r.value_denominator, r.source
  FROM rows r
  ORDER BY r.period_start ASC, r.kpi_code ASC;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_snapshot_series(date, integer, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_snapshot_series(date, integer, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_snapshot_series(date, integer, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_snapshot_series_live covering the same six lightweight KPIs, without auth so it runs in the SQL editor. Not exposed via PostgREST.';
