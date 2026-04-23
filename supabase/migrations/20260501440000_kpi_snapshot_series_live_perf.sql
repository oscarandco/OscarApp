-- =====================================================================
-- KPI monthly trends — performance refactor (no math changes).
--
-- Why this migration exists
-- -------------------------
-- The previous implementation
-- (20260501430000_kpi_snapshot_series_live.sql) loops the FULL snapshot
-- dispatcher month-by-month. For a 12-month window that produced:
--
--   12  ×  public.get_kpi_snapshot_live  (nested SECURITY DEFINER)
--   12  ×  private.kpi_resolve_scope     (in the dispatcher itself)
--  132  ×  per-KPI live RPC              (12 months × 11 KPIs)
--  132  ×  private.kpi_resolve_scope     (re-validation inside each
--                                         per-KPI RPC; intentional)
--
-- ~144 redundant scope resolutions and 12 nested SECURITY DEFINER
-- frames per series request, on top of the unavoidable 132 per-KPI
-- computations. This is what is timing out at 12 months.
--
-- Refactor (smallest safe change)
-- -------------------------------
--   * Resolve scope ONCE at the top of the public wrapper.
--   * Bypass the snapshot dispatcher entirely.
--   * UNION ALL the 11 existing private.debug_kpi_* helpers directly,
--     each LATERAL-joined to a single generate_series of month anchors.
--     These are the same per-KPI math the snapshot dispatcher's debug
--     mirror uses today, and they have no internal auth check (they
--     are SECURITY INVOKER private helpers).
--   * The public wrapper stays SECURITY DEFINER — auth is enforced
--     once via private.kpi_resolve_scope at the top, so calling the
--     private helpers from inside the wrapper is safe.
--
-- KPI correctness
-- ---------------
-- The per-KPI debug helpers are the canonical computational kernels:
-- the snapshot dispatcher's debug branch already uses them and they
-- are kept in lockstep with the per-KPI live RPCs. Therefore the
-- refactored series RPC returns the same numeric values as the prior
-- implementation. No KPI definition, math, or output shape changes
-- here. The 12-column return shape is preserved.
--
-- Public/private signatures and grants are intentionally identical
-- to the previous migration so the frontend hook needs no change.
--
-- Performance bound
-- -----------------
-- p_month_count is still bounded 1..36. With 36 months × 11 KPIs the
-- worst case is 396 per-KPI calls (unchanged from before) but with
-- exactly 1 scope resolution and zero nested dispatcher frames.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_snapshot_series_live (auth-enforced; one resolve)
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
  -- Stylist / assistant callers are silently collapsed to their own
  -- staff scope here, identical to the snapshot dispatcher.
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

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_client_frequency(m.m_start, v_scope, v_loc_id, v_staff_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_client_retention_6m(m.m_start, v_scope, v_loc_id, v_staff_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_client_retention_12m(m.m_start, v_scope, v_loc_id, v_staff_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_new_client_retention_6m(m.m_start, v_scope, v_loc_id, v_staff_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_new_client_retention_12m(m.m_start, v_scope, v_loc_id, v_staff_id) d
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
'Monthly KPI trends. Resolves auth + scope ONCE via private.kpi_resolve_scope, then UNION ALLs the 11 per-KPI debug helpers (private.debug_kpi_*) LATERAL-joined to a generate_series of month-start anchors. Bypasses the snapshot dispatcher to avoid 12 nested SECURITY DEFINER frames and ~144 redundant scope resolutions per 12-month series. KPI math is unchanged: the per-KPI debug helpers are the same kernels used by private.debug_kpi_snapshot. Locked 12-column shape, ordered (period_start ASC, kpi_code ASC). p_month_count bounded 1..36.';


-- ---------------------------------------------------------------------
-- 2. private.debug_kpi_snapshot_series (validation; SECURITY INVOKER)
--
-- Mirrors the public wrapper but skips kpi_resolve_scope (auth.uid()
-- is NULL in the SQL editor) and just normalises/validates the
-- caller-supplied scope, exactly like private.debug_kpi_snapshot does
-- today. Same 11-way UNION ALL across LATERAL per-KPI helpers.
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

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_client_frequency(m.m_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_client_retention_6m(m.m_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_client_retention_12m(m.m_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_new_client_retention_6m(m.m_start, v_scope, p_location_id, p_staff_member_id) d

    UNION ALL
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM months m,
         LATERAL private.debug_kpi_new_client_retention_12m(m.m_start, v_scope, p_location_id, p_staff_member_id) d
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
'DEBUG / VALIDATION ONLY. Same per-KPI direct UNION ALL design as public.get_kpi_snapshot_series_live, but SECURITY INVOKER and without kpi_resolve_scope so it runs in the SQL editor (auth.uid() is NULL). Not exposed via PostgREST.';
