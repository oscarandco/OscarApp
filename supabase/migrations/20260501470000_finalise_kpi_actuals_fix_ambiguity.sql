-- =====================================================================
-- Fix: private.finalise_kpi_actuals_for_month — resolve 42702 ambiguity.
--
-- Symptom
--   ERROR 42702: column reference "kpi_code" is ambiguous
--
-- Cause
--   RETURNS TABLE (kpi_code text, action text) makes `kpi_code` an
--   implicit OUT parameter inside the function body. The upsert CTE's
--     RETURNING (xmax = 0) AS was_insert, kpi_code
--   could bind `kpi_code` to either the OUT parameter or the target
--   table's column on public.kpi_actuals_monthly, so the planner
--   refused to choose.
--
-- Fix
--   Rename the inner column returned by the upsert CTE to
--   `row_kpi_code`, then project it back to `kpi_code` at the
--   outermost SELECT. Function contract, table design, KPI math
--   source, and idempotency are all unchanged. This is a pure
--   CREATE OR REPLACE of the finalisation RPC.
-- =====================================================================


CREATE OR REPLACE FUNCTION private.finalise_kpi_actuals_for_month(
  p_period_start date
)
RETURNS TABLE (
  kpi_code text,
  action   text
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period        date := p_period_start;
  v_current_month date := date_trunc('month', current_date)::date;
BEGIN
  IF v_period IS NULL THEN
    RAISE EXCEPTION 'finalise_kpi_actuals_for_month: p_period_start is required'
      USING ERRCODE = '22023';
  END IF;

  IF v_period <> date_trunc('month', v_period)::date THEN
    RAISE EXCEPTION
      'finalise_kpi_actuals_for_month: p_period_start must be first-of-month, got %',
      v_period
      USING ERRCODE = '22023';
  END IF;

  IF v_period >= v_current_month THEN
    RAISE EXCEPTION
      'finalise_kpi_actuals_for_month: refuses to finalise the current open month or a future month (p_period_start %, current month %)',
      v_period, v_current_month
      USING ERRCODE = '22023';
  END IF;

  RETURN QUERY
  WITH computed AS (
    SELECT d.kpi_code, d.scope_type, d.location_id, d.staff_member_id,
           d.period_start, d.period_end, d.mtd_through, d.is_current_open_month,
           d.value, d.value_numerator, d.value_denominator, d.source
    FROM private.debug_kpi_snapshot(v_period, 'business', NULL, NULL) d
  ),
  upserted AS (
    INSERT INTO public.kpi_actuals_monthly AS t (
      kpi_code, scope_type, location_id, staff_member_id,
      period_start, period_end, mtd_through, is_current_open_month,
      value, value_numerator, value_denominator, source,
      recorded_at, source_version
    )
    SELECT c.kpi_code, c.scope_type, c.location_id, c.staff_member_id,
           c.period_start, c.period_end, c.mtd_through, c.is_current_open_month,
           c.value, c.value_numerator, c.value_denominator, c.source,
           now(), 1
    FROM computed c
    ON CONFLICT ON CONSTRAINT kpi_actuals_monthly_natural_key
    DO UPDATE SET
      period_end            = EXCLUDED.period_end,
      mtd_through           = EXCLUDED.mtd_through,
      is_current_open_month = EXCLUDED.is_current_open_month,
      value                 = EXCLUDED.value,
      value_numerator       = EXCLUDED.value_numerator,
      value_denominator     = EXCLUDED.value_denominator,
      source                = EXCLUDED.source,
      recorded_at           = now(),
      source_version        = t.source_version + 1
    -- Inner alias row_kpi_code avoids the collision with the
    -- RETURNS TABLE OUT parameter `kpi_code` (was the source of
    -- the 42702 error). xmax = 0 is the standard idiom for
    -- distinguishing a fresh INSERT from an ON CONFLICT DO UPDATE.
    RETURNING (xmax = 0) AS was_insert, t.kpi_code AS row_kpi_code
  )
  SELECT u.row_kpi_code                                          AS kpi_code,
         CASE WHEN u.was_insert THEN 'inserted' ELSE 'updated' END AS action
  FROM upserted u
  ORDER BY u.row_kpi_code;
END;
$fn$;

ALTER FUNCTION private.finalise_kpi_actuals_for_month(date) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.finalise_kpi_actuals_for_month(date) FROM PUBLIC;

COMMENT ON FUNCTION private.finalise_kpi_actuals_for_month(date) IS
'Upsert all business-scope KPIs for a CLOSED month into public.kpi_actuals_monthly via private.debug_kpi_snapshot. Rejects current open month and future months. Idempotent: reruns overwrite existing rows, refresh recorded_at, and bump source_version. v1 scope: business only. Ambiguity fix (42702) applied 20260501470000.';
