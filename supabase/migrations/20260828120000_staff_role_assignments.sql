-- Effective-dated staff role/pay history — Phase 1 (data model only).
--
-- Adds public.staff_role_assignments with one open-ended row per existing
-- staff_member backfilled from current staff_members values, plus a
-- staff_profile_at(p_staff, p_date) lookup helper.
--
-- IMPORTANT (Phase 1 invariants):
--   * No payroll view, KPI RPC, contractor invoice RPC, or reporting view
--     reads this table yet. Behaviour is unchanged.
--   * The backfill creates a single open-ended assignment per staff member
--     that matches today's staff_members values exactly, so
--     staff_profile_at(staff_id, current_date) returns the same role/plan/
--     employment/fte/primary_location as staff_members.
--   * Phase 2 (separate migration) will reroute v_sales_transactions_powerbi_parity,
--     v_commission_calculations_core, and v_sales_transactions_enriched to
--     read from this table instead of joining staff_members directly.
--   * Staff Admin UI is unchanged in Phase 1 — direct UPDATEs to staff_members
--     still work and do NOT mirror into staff_role_assignments yet. Phase 4
--     will add the upsert RPC + UI; until then the history table is read-only
--     to all callers other than this migration's backfill.
--
-- Spec source: investigation/design report (Bernie–Lorine recalculation bug).

-- ---------------------------------------------------------------------------
-- 0. Extension: btree_gist (needed for the no-overlap EXCLUDE constraint).
--    Supabase already enables this for managed Postgres projects; the
--    IF NOT EXISTS guard keeps the migration idempotent and safe for local.
-- ---------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- ---------------------------------------------------------------------------
-- 1. Table: public.staff_role_assignments
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.staff_role_assignments (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  staff_member_id       uuid NOT NULL
                          REFERENCES public.staff_members(id) ON DELETE CASCADE,
  effective_start_date  date NOT NULL,
  effective_end_date    date NULL,
  primary_role          text NULL,
  secondary_roles       text NULL,
  employment_type       text NULL,
  remuneration_plan     text NULL,
  fte                   numeric(5, 4) NULL,
  primary_location_id   uuid NULL
                          REFERENCES public.locations(id) ON DELETE SET NULL,
  reason                text NULL,
  created_at            timestamptz NOT NULL DEFAULT now(),
  created_by            uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  updated_at            timestamptz NOT NULL DEFAULT now(),
  updated_by            uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,

  -- Sanity: end must be NULL (open) or on/after start.
  CONSTRAINT staff_role_assignments_range_valid
    CHECK (effective_end_date IS NULL OR effective_end_date >= effective_start_date),

  -- No overlapping windows per staff member. Half-open NULL = infinity.
  -- daterange '[]' is inclusive on both ends, matching the lookup rule
  --   effective_start_date <= sale_date <= effective_end_date.
  -- DEFERRABLE so a future "close previous + insert new" RPC can run
  -- both DML statements in a single transaction without tripping the
  -- check in the middle.
  CONSTRAINT staff_role_assignments_no_overlap
    EXCLUDE USING gist (
      staff_member_id WITH =,
      daterange(
        effective_start_date,
        COALESCE(effective_end_date, 'infinity'::date),
        '[]'
      ) WITH &&
    ) DEFERRABLE INITIALLY IMMEDIATE
);

ALTER TABLE public.staff_role_assignments OWNER TO postgres;

COMMENT ON TABLE  public.staff_role_assignments IS
  'Effective-dated history of staff role / remuneration plan / employment type / FTE / primary location. NOT yet consumed by any view or RPC (Phase 1). Will be consumed by v_sales_transactions_powerbi_parity, v_commission_calculations_core, v_sales_transactions_enriched, and FTE KPIs in Phase 2.';
COMMENT ON COLUMN public.staff_role_assignments.effective_start_date IS 'Inclusive start of this assignment. Used as: sale_date >= effective_start_date.';
COMMENT ON COLUMN public.staff_role_assignments.effective_end_date   IS 'Inclusive end of this assignment. NULL means the assignment is still open. Used as: sale_date <= effective_end_date OR effective_end_date IS NULL.';
COMMENT ON COLUMN public.staff_role_assignments.reason               IS 'Free text audit note, e.g. "Promoted to Stylist", "FTE change", "Initial backfill from current staff profile".';
COMMENT ON COLUMN public.staff_role_assignments.primary_location_id  IS 'Effective-dated primary location. Mirrors staff_members.primary_location_id at the time the assignment was active.';

-- Lookup helper indexes.
-- 1. Fast "latest open row per staff" and "what was the role at date X".
CREATE INDEX IF NOT EXISTS staff_role_assignments_staff_start_desc_idx
  ON public.staff_role_assignments (staff_member_id, effective_start_date DESC);
-- 2. Index to support "who was at this location effective on X" if it ever lands.
CREATE INDEX IF NOT EXISTS staff_role_assignments_primary_location_idx
  ON public.staff_role_assignments (primary_location_id)
  WHERE primary_location_id IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 2. updated_at trigger — reuse the project-wide public.set_updated_at()
--    so this table follows the same convention as staff_members.
-- ---------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_staff_role_assignments_updated_at
  ON public.staff_role_assignments;
CREATE TRIGGER trg_staff_role_assignments_updated_at
  BEFORE UPDATE ON public.staff_role_assignments
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();


-- ---------------------------------------------------------------------------
-- 3. RLS + grants — mirror staff_members (elevated users only).
--    Phase 4 will add an upsert RPC; for now we want elevated callers to be
--    able to read for verification, but writes are limited to this migration's
--    backfill (run as postgres). authenticated callers receive SELECT/INSERT/
--    UPDATE table grants matching staff_members, then RLS limits to elevated.
-- ---------------------------------------------------------------------------
ALTER TABLE public.staff_role_assignments ENABLE ROW LEVEL SECURITY;

GRANT SELECT, INSERT, UPDATE ON public.staff_role_assignments TO authenticated;

DROP POLICY IF EXISTS "staff_role_assignments_elevated_select" ON public.staff_role_assignments;
DROP POLICY IF EXISTS "staff_role_assignments_elevated_insert" ON public.staff_role_assignments;
DROP POLICY IF EXISTS "staff_role_assignments_elevated_update" ON public.staff_role_assignments;

CREATE POLICY "staff_role_assignments_elevated_select"
  ON public.staff_role_assignments
  FOR SELECT
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()));

CREATE POLICY "staff_role_assignments_elevated_insert"
  ON public.staff_role_assignments
  FOR INSERT
  TO authenticated
  WITH CHECK ((SELECT private.user_has_elevated_access()));

CREATE POLICY "staff_role_assignments_elevated_update"
  ON public.staff_role_assignments
  FOR UPDATE
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()))
  WITH CHECK ((SELECT private.user_has_elevated_access()));

-- No DELETE policy: history must not be silently deleted. ON DELETE CASCADE
-- from staff_members handles the only legitimate hard-delete path (delete
-- the staff master row → its history rows go with it).


-- ---------------------------------------------------------------------------
-- 4. Helper: public.staff_profile_at(p_staff uuid, p_date date)
--    Returns the staff_role_assignments row that was effective for the given
--    staff member on the given date. SETOF return so future view code can
--    LATERAL-join it cleanly.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.staff_profile_at(
  p_staff uuid,
  p_date  date
)
RETURNS SETOF public.staff_role_assignments
LANGUAGE sql
STABLE
PARALLEL SAFE
SET search_path = public, pg_temp
AS $fn$
  SELECT a.*
  FROM public.staff_role_assignments a
  WHERE a.staff_member_id = p_staff
    AND a.effective_start_date <= p_date
    AND (a.effective_end_date IS NULL OR a.effective_end_date >= p_date)
  ORDER BY a.effective_start_date DESC
  LIMIT 1;
$fn$;

ALTER FUNCTION public.staff_profile_at(uuid, date) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.staff_profile_at(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.staff_profile_at(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.staff_profile_at(uuid, date) TO service_role;

COMMENT ON FUNCTION public.staff_profile_at(uuid, date) IS
  'Returns the staff_role_assignments row effective for the given staff_member_id on the given date. Inclusive on both ends; NULL effective_end_date is treated as open (infinity). Returns zero rows if no assignment covers the date (e.g. date is before the staff member''s earliest assignment). Used by future commission/payroll/KPI views to read effective-dated role/plan/employment/fte/primary_location.';


-- ---------------------------------------------------------------------------
-- 5. Backfill — one open-ended assignment per staff_members row.
--    Idempotent guard: skip if any history rows already exist (lets this
--    migration be re-applied safely against a partially-built environment).
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_existing integer;
  v_inserted integer;
BEGIN
  SELECT count(*) INTO v_existing FROM public.staff_role_assignments;
  IF v_existing > 0 THEN
    RAISE NOTICE 'staff_role_assignments backfill skipped: % rows already present', v_existing;
    RETURN;
  END IF;

  INSERT INTO public.staff_role_assignments (
    staff_member_id,
    effective_start_date,
    effective_end_date,
    primary_role,
    secondary_roles,
    employment_type,
    remuneration_plan,
    fte,
    primary_location_id,
    reason
  )
  SELECT
    sm.id,
    -- Earliest sensible start. Per spec: employment_start_date first,
    -- then first_seen_sale_date (already populated on staff_members),
    -- then a permissive sentinel so the join never fails for legacy rows.
    COALESCE(
      sm.employment_start_date,
      sm.first_seen_sale_date,
      DATE '1900-01-01'
    ),
    NULL,                       -- open-ended
    sm.primary_role,
    sm.secondary_roles,
    sm.employment_type,
    sm.remuneration_plan,
    sm.fte,
    sm.primary_location_id,
    'Initial backfill from current staff profile'
  FROM public.staff_members sm;

  GET DIAGNOSTICS v_inserted = ROW_COUNT;
  RAISE NOTICE 'staff_role_assignments backfill inserted % rows', v_inserted;
END
$$;
