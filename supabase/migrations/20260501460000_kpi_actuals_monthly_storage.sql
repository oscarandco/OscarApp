-- =====================================================================
-- KPI actuals — monthly storage + business-scope finalisation writer.
--
-- Purpose
-- -------
-- Start the durable monthly-actuals layer for KPI trends. On-demand
-- live series against v_sales_transactions_enriched is too expensive
-- for retention/frequency KPIs at production volumes; instead we
-- materialise closed-month KPI values into a persistent table and
-- plan to read chart series from that table in a later slice.
--
-- What this slice contains
-- ------------------------
--   1. public.kpi_actuals_monthly
--        table, 12-column KPI snapshot shape + recorded_at/source_version
--        RLS ENABLED with no policies (locked down)
--        Unique natural key with NULLS NOT DISTINCT so business-scope
--        rows (both scope id columns NULL) collide correctly on rerun
--
--   2. private.finalise_kpi_actuals_for_month(p_period_start date)
--        SECURITY DEFINER writer, BUSINESS scope only (v1)
--        rejects current-open-month and future months
--        calls private.debug_kpi_snapshot (the same math kernel
--          Snapshot already uses) - no formula duplication
--        idempotent upsert via the named natural-key constraint
--        bumps source_version + recorded_at on rerun
--
-- What this slice deliberately does NOT contain
-- ---------------------------------------------
--   * No location/staff scope materialisation (v1 is business only)
--   * No scheduler / pg_cron wiring
--   * No reader RPC / view
--   * No UI
--   * No KPI math changes
--
-- Retention caveat
-- ----------------
-- For retention KPIs (client_retention_*, new_client_retention_*) a
-- "closed reporting month" does NOT mean the return window is also
-- complete - e.g. new_client_retention_6m for March 2026 has a return
-- window through September 2026. Finalising the row today will store
-- the MTD-clipped value the same way Snapshot already does (maturity
-- encoded in `source`). Rerunning this RPC later simply refreshes
-- the row. That is exactly what idempotency + source_version bumping
-- is here for. Consumers that care about maturity can continue to
-- read it from `source`.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Table: public.kpi_actuals_monthly
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.kpi_actuals_monthly (
  id                    bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  kpi_code              text        NOT NULL,
  scope_type            text        NOT NULL,
  location_id           uuid,
  staff_member_id       uuid,
  period_start          date        NOT NULL,
  period_end            date        NOT NULL,
  mtd_through           date        NOT NULL,
  is_current_open_month boolean     NOT NULL,
  value                 numeric(18, 4),
  value_numerator       numeric(18, 4),
  value_denominator     numeric(18, 4),
  source                text        NOT NULL,
  recorded_at           timestamptz NOT NULL DEFAULT now(),
  source_version        integer     NOT NULL DEFAULT 1,

  CONSTRAINT kpi_actuals_monthly_scope_type_chk
    CHECK (scope_type IN ('business', 'location', 'staff')),

  -- Scope-consistency: exactly the id columns required for each
  -- scope are populated, the others are NULL. Prevents malformed
  -- rows such as scope_type='business' with a location_id set.
  CONSTRAINT kpi_actuals_monthly_scope_ids_chk CHECK (
       (scope_type = 'business'
          AND location_id IS NULL
          AND staff_member_id IS NULL)
    OR (scope_type = 'location'
          AND location_id IS NOT NULL
          AND staff_member_id IS NULL)
    OR (scope_type = 'staff'
          AND staff_member_id IS NOT NULL
          AND location_id IS NULL)
  ),

  CONSTRAINT kpi_actuals_monthly_period_start_first_of_month_chk
    CHECK (EXTRACT(DAY FROM period_start) = 1),

  CONSTRAINT kpi_actuals_monthly_period_range_chk
    CHECK (period_end >= period_start AND mtd_through >= period_start),

  -- Natural key with NULLS NOT DISTINCT so that business-scope rows
  -- (location_id/staff_member_id both NULL) still uniqueness-collide
  -- correctly on rerun. Referenced by name in ON CONFLICT below.
  CONSTRAINT kpi_actuals_monthly_natural_key
    UNIQUE NULLS NOT DISTINCT
    (kpi_code, scope_type, location_id, staff_member_id, period_start)
);

COMMENT ON TABLE public.kpi_actuals_monthly IS
'Materialised monthly KPI values for closed months (v1: business scope only). Writers go through private.finalise_kpi_actuals_for_month. Direct access locked via RLS (no policies); future reads will go through SECURITY DEFINER read RPCs. Row shape mirrors the locked 12-column KPI snapshot shape plus recorded_at / source_version bookkeeping.';

COMMENT ON COLUMN public.kpi_actuals_monthly.source IS
'Free-text provenance string copied from the underlying debug helper (e.g. "live|mature=true"). Maturity for retention KPIs is encoded here - consumers should read this if they care.';

COMMENT ON COLUMN public.kpi_actuals_monthly.source_version IS
'Monotonic counter bumped on every upsert for the same natural-key row. Makes reruns auditable without touching the row shape.';

-- Read patterns supported:
--   * chart series per KPI across months:
--     WHERE kpi_code = ? AND scope_type = ?
--     ORDER BY period_start
CREATE INDEX IF NOT EXISTS kpi_actuals_monthly_kpi_period_idx
  ON public.kpi_actuals_monthly (kpi_code, period_start DESC);

--   * scope-filtered reads (all KPIs for a scope across months):
--     WHERE scope_type = ? AND location_id ?= AND staff_member_id ?=
--     ORDER BY period_start
CREATE INDEX IF NOT EXISTS kpi_actuals_monthly_scope_period_idx
  ON public.kpi_actuals_monthly
    (scope_type, location_id, staff_member_id, period_start DESC);

ALTER TABLE public.kpi_actuals_monthly OWNER TO postgres;
ALTER TABLE public.kpi_actuals_monthly ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.kpi_actuals_monthly FROM PUBLIC;
REVOKE ALL ON TABLE public.kpi_actuals_monthly FROM authenticated;
REVOKE ALL ON TABLE public.kpi_actuals_monthly FROM anon;
-- service_role is BYPASSRLS in Supabase; no explicit grant needed.


-- ---------------------------------------------------------------------
-- 2. private.finalise_kpi_actuals_for_month(p_period_start date)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.finalise_kpi_actuals_for_month(
  p_period_start date
)
RETURNS TABLE (
  kpi_code text,
  action   text   -- 'inserted' | 'updated'
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

  -- Guard: this RPC is ONLY for closed reporting months. We refuse
  -- the current open month and any future month outright. (Retention
  -- KPIs whose return windows extend past p_period_start are still
  -- allowed - see the file header: idempotent rerun refreshes them.)
  IF v_period >= v_current_month THEN
    RAISE EXCEPTION
      'finalise_kpi_actuals_for_month: refuses to finalise the current open month or a future month (p_period_start %, current month %)',
      v_period, v_current_month
      USING ERRCODE = '22023';
  END IF;

  -- Single call to the existing snapshot debug kernel. Returns one
  -- row per KPI for business scope. No KPI math lives here; any
  -- future fix to per-KPI helpers flows through automatically.
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
    -- xmax = 0 is the standard idiom for distinguishing a fresh
    -- INSERT from an ON CONFLICT DO UPDATE path.
    RETURNING (xmax = 0) AS was_insert, kpi_code
  )
  SELECT u.kpi_code,
         CASE WHEN u.was_insert THEN 'inserted' ELSE 'updated' END AS action
  FROM upserted u
  ORDER BY u.kpi_code;
END;
$fn$;

ALTER FUNCTION private.finalise_kpi_actuals_for_month(date) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.finalise_kpi_actuals_for_month(date) FROM PUBLIC;
-- Intentionally NOT granted to authenticated / anon / service_role in
-- this slice. Call from the Supabase SQL editor (runs as postgres)
-- until a scheduler / admin wiring lands.

COMMENT ON FUNCTION private.finalise_kpi_actuals_for_month(date) IS
'Upsert all business-scope KPIs for a CLOSED month into public.kpi_actuals_monthly via private.debug_kpi_snapshot. Rejects current open month and future months. Idempotent: reruns overwrite existing rows, refresh recorded_at, and bump source_version. v1 scope: business only. Location / staff actuals are a later additive slice. Retention KPIs with return windows extending past p_period_start store their current MTD-clipped values (maturity in `source`); rerun after the window matures to refresh.';
