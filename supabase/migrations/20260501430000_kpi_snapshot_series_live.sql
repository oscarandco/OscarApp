-- =====================================================================
-- KPI monthly trends: snapshot series RPC + debug mirror.
--
-- Purpose
-- -------
-- The KPI dashboard needs a per-month view of the same KPIs the
-- snapshot dispatcher exposes, so we can inspect behaviour over time
-- (and surface potentially-incorrect KPIs per month for diagnosis).
--
-- Design rule (locked)
-- --------------------
-- Trends MUST be a read-only consumer of the existing live KPI logic.
-- This wrapper does not implement any KPI math of its own: it only
-- generates month-start dates and LATERAL-calls
-- public.get_kpi_snapshot_live once per month. Any future fix to a
-- per-KPI live RPC (or to the dispatcher) flows through to Trends
-- automatically, keeping Snapshot and Trends aligned by construction.
--
-- Implementation
-- --------------
--   public.get_kpi_snapshot_series_live   (auth-enforced)
--   private.debug_kpi_snapshot_series     (validation only; no auth)
--
-- Input params
--   p_month_start     date default null    -- anchor month (first-of-month).
--                                             NULL = current calendar month.
--   p_month_count     integer default 12   -- number of months returned,
--                                             bounded 1..36.
--   p_scope           text default 'business'
--   p_location_id     uuid default null
--   p_staff_member_id uuid default null
--
-- Window semantics
-- ----------------
-- Returns `p_month_count` trailing months ending at `p_month_start`.
-- With the default anchor (current month) and default count (12) the
-- result is exactly the trailing 12 months through today, where the
-- anchor month is the last (right-most) in the series. Rows are
-- ordered `period_start ASC, kpi_code ASC` so a frontend can render
-- month-by-month without re-sorting.
--
-- Auth / scope
-- ------------
-- Identical to the snapshot dispatcher. `public.get_kpi_snapshot_live`
-- internally calls `private.kpi_resolve_scope`, which silently
-- collapses stylist / assistant callers to their own staff scope. We
-- intentionally re-resolve scope per month (the call is trivial) so
-- this wrapper stays a strict consumer of the dispatcher's contract
-- rather than reimplementing any part of it.
--
-- Return shape
-- ------------
-- Identical to public.get_kpi_snapshot_live (locked 12-column shape).
-- One row per (kpi_code, month).
--
-- Performance
-- -----------
-- p_month_count is bounded to 36 so a single call executes at most
-- 36 dispatcher invocations (~ 36 * 11 KPI RPCs = 396 live KPI rows
-- returned per call). That is well within the existing per-KPI
-- performance envelope at current data volume and keeps any request
-- timeout risk capped.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_snapshot_series_live  (auth-enforced)
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
  v_anchor date;
  v_count  integer;
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

  RETURN QUERY
  WITH months AS (
    SELECT (v_anchor - (g.i * interval '1 month'))::date AS m_start
    FROM generate_series(0, v_count - 1) AS g(i)
  )
  SELECT s.*
  FROM months m,
       LATERAL public.get_kpi_snapshot_live(
         m.m_start, p_scope, p_location_id, p_staff_member_id
       ) s
  ORDER BY s.period_start ASC, s.kpi_code ASC;
END;
$fn$;

ALTER FUNCTION public.get_kpi_snapshot_series_live(date, integer, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_snapshot_series_live(date, integer, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_snapshot_series_live(date, integer, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_snapshot_series_live(date, integer, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_snapshot_series_live(date, integer, text, uuid, uuid) IS
'Monthly KPI trends. Generates `p_month_count` trailing month-starts ending at `p_month_start` (or current month) and LATERAL-calls public.get_kpi_snapshot_live once per month. No KPI math lives here: any future fix to a per-KPI live RPC flows through automatically. Locked 12-column shape per row, ordered (period_start ASC, kpi_code ASC). p_month_count is bounded 1..36.';


-- ---------------------------------------------------------------------
-- 2. private.debug_kpi_snapshot_series  (validation only; SECURITY INVOKER)
--
-- Mirrors the public wrapper but dispatches to private.debug_kpi_snapshot
-- so it can be exercised in the Supabase SQL editor (auth.uid() NULL
-- there). Not exposed via PostgREST. Drop when the v1 KPI validation
-- phase is over, alongside the other debug_kpi_* helpers.
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
  v_anchor date := COALESCE(p_month_start, date_trunc('month', current_date)::date);
  v_count  integer := COALESCE(p_month_count, 12);
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

  RETURN QUERY
  WITH months AS (
    SELECT (v_anchor - (g.i * interval '1 month'))::date AS m_start
    FROM generate_series(0, v_count - 1) AS g(i)
  )
  SELECT s.*
  FROM months m,
       LATERAL private.debug_kpi_snapshot(
         m.m_start, p_scope, p_location_id, p_staff_member_id
       ) s
  ORDER BY s.period_start ASC, s.kpi_code ASC;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_snapshot_series(date, integer, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_snapshot_series(date, integer, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_snapshot_series(date, integer, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Monthly mirror of the KPI snapshot. Dispatches via private.debug_kpi_snapshot per month. Not exposed via PostgREST.';
