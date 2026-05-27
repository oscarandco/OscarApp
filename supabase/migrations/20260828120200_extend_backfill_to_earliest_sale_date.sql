-- Phase 1 backfill coverage fix: extend each initial open-ended assignment's
-- effective_start_date backwards so it covers every historic sales_transactions
-- row in which the staff member appears as staff_work_id, staff_commission_id,
-- or staff_paid_id.
--
-- Why this is needed
--   The original Phase 1 backfill (20260828120000) used:
--       coalesce(employment_start_date, first_seen_sale_date, '1900-01-01')
--   For some staff, employment_start_date is later than the earliest imported
--   sale_date that references them. After Phase 2 (20260828120100), the
--   COALESCE fallback in the views still produces today's numbers, but the
--   staff_role_assignments table no longer "covers" those historic sales —
--   meaning any Phase 4 historical correction wouldn't reach them either.
--
--   Validation snapshot pre-fix:
--     staff_work_id        rows_checked=9924  no_effective_profile=2585
--     staff_commission_id  rows_checked=9501  no_effective_profile=2758
--
-- Fix
--   For each staff_role_assignments row that is the initial open-ended
--   backfill row (reason = 'Initial backfill from current staff profile'
--   AND effective_end_date IS NULL), set effective_start_date to the
--   earliest covering date.
--
--   The user spec listed two formulations:
--     (a) LEAST(existing effective_start_date, earliest_sale_date,
--               employment_start_date)
--     (b) COALESCE priority: earliest_sale_date, then employment_start_date,
--         then existing, then '1900-01-01'.
--
--   We use (a) — LEAST. Rationale:
--     * (a) is strictly more conservative: it never moves the start date
--       forward, so we cannot accidentally drop coverage for a staff member
--       whose employment_start_date is earlier than their earliest sale
--       (e.g. employed Jan; first sale Jun → keep Jan).
--     * (a) satisfies the explicit goal ("ensure every historic sale is
--       covered") because LEAST(<everything>) <= earliest_sale_date whenever
--       earliest_sale_date is non-NULL.
--     * Falls back to '1900-01-01' only if literally nothing covers the
--       staff member (no sales AND no employment_start_date AND existing was
--       already '1900-01-01').
--
--   LEAST() ignores NULL inputs natively, so staff with no sales contribute
--   only their (existing, employment_start_date) and stay put.
--
-- Scope guards
--   * Only updates rows where reason = 'Initial backfill from current staff
--     profile' AND effective_end_date IS NULL. Future history rows added by
--     Phase 4 admin actions are untouched.
--   * Does NOT change role / remuneration_plan / employment_type / fte /
--     primary_location_id on any row.
--   * Does NOT insert new history rows.
--   * Does NOT touch views, RPCs, or any frontend types.
--
-- Behavioural impact on payroll / KPI numbers
--   None today. The Phase 2 COALESCE fallback was already producing today's
--   staff_members values for uncovered (staff_id, sale_date) pairs. After
--   this migration the effective lookup succeeds and returns the same values
--   (the backfilled row mirrors current staff_members), so payroll / KPI /
--   contractor invoice totals are byte-identical before and after. The fix
--   is purely a coverage prerequisite for Phase 4 historical corrections to
--   take effect on historic sales.

-- ---------------------------------------------------------------------------
-- 1. Apply the extension and report rows updated via RAISE NOTICE.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_updated integer;
BEGIN
  WITH staff_earliest_sale AS (
    SELECT staff_id, MIN(sale_date) AS earliest_sale_date
    FROM (
      SELECT st.staff_work_id       AS staff_id, st.sale_date
        FROM public.sales_transactions st
       WHERE st.staff_work_id IS NOT NULL
      UNION ALL
      SELECT st.staff_commission_id AS staff_id, st.sale_date
        FROM public.sales_transactions st
       WHERE st.staff_commission_id IS NOT NULL
      UNION ALL
      SELECT st.staff_paid_id       AS staff_id, st.sale_date
        FROM public.sales_transactions st
       WHERE st.staff_paid_id IS NOT NULL
    ) refs
    GROUP BY staff_id
  ),
  desired AS (
    SELECT
      a.id                              AS assignment_id,
      a.effective_start_date            AS current_start,
      LEAST(
        a.effective_start_date,
        ses.earliest_sale_date,
        sm.employment_start_date
      )                                 AS new_start
    FROM public.staff_role_assignments a
    JOIN public.staff_members sm
      ON sm.id = a.staff_member_id
    LEFT JOIN staff_earliest_sale ses
      ON ses.staff_id = a.staff_member_id
    WHERE a.reason = 'Initial backfill from current staff profile'
      AND a.effective_end_date IS NULL
  )
  UPDATE public.staff_role_assignments tgt
     SET effective_start_date = d.new_start
    FROM desired d
   WHERE tgt.id = d.assignment_id
     AND d.new_start < d.current_start;

  GET DIAGNOSTICS v_updated = ROW_COUNT;
  RAISE NOTICE 'staff_role_assignments backfill extension updated % rows', v_updated;
END
$$;


-- ---------------------------------------------------------------------------
-- 2. Post-migration smoke check baked into the migration. Raises if any
--    sales row still lacks a covering effective profile for the staff
--    references we actually use in the commission pipeline.
--    (UPDATE leaves no_effective_profile = 0 if it ran correctly.)
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_work_uncovered       integer;
  v_commission_uncovered integer;
  v_paid_uncovered       integer;
BEGIN
  SELECT count(*)
    INTO v_work_uncovered
  FROM public.sales_transactions st
  WHERE st.staff_work_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.staff_role_assignments a
      WHERE a.staff_member_id = st.staff_work_id
        AND a.effective_start_date <= st.sale_date
        AND (a.effective_end_date IS NULL OR a.effective_end_date >= st.sale_date)
    );

  SELECT count(*)
    INTO v_commission_uncovered
  FROM public.sales_transactions st
  WHERE st.staff_commission_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.staff_role_assignments a
      WHERE a.staff_member_id = st.staff_commission_id
        AND a.effective_start_date <= st.sale_date
        AND (a.effective_end_date IS NULL OR a.effective_end_date >= st.sale_date)
    );

  SELECT count(*)
    INTO v_paid_uncovered
  FROM public.sales_transactions st
  WHERE st.staff_paid_id IS NOT NULL
    AND NOT EXISTS (
      SELECT 1
      FROM public.staff_role_assignments a
      WHERE a.staff_member_id = st.staff_paid_id
        AND a.effective_start_date <= st.sale_date
        AND (a.effective_end_date IS NULL OR a.effective_end_date >= st.sale_date)
    );

  RAISE NOTICE 'post-extend coverage: work=%, commission=%, paid=%',
    v_work_uncovered, v_commission_uncovered, v_paid_uncovered;

  -- Defensive: if anything is still uncovered, abort. This shouldn't fire
  -- because LEAST() includes the earliest sale date by construction, but
  -- the assertion documents the contract and protects future re-runs.
  IF (v_work_uncovered + v_commission_uncovered + v_paid_uncovered) > 0 THEN
    RAISE EXCEPTION
      'staff_role_assignments coverage gap after extension: work=%, commission=%, paid=%',
      v_work_uncovered, v_commission_uncovered, v_paid_uncovered;
  END IF;
END
$$;
