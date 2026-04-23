-- =====================================================================
-- Stylist comparison RPC — narrow to the lightweight KPI subset.
--
-- Context
-- -------
-- The original migration
--   20260501500000_kpi_stylist_comparisons_live_rpc.sql
-- wired nine KPIs through a `CROSS JOIN LATERAL` over the active
-- stylist cohort. At real-world cohort sizes, four of those helpers —
--   private.debug_kpi_client_frequency
--   private.debug_kpi_client_retention_6m
--   private.debug_kpi_client_retention_12m
--   private.debug_kpi_assistant_utilisation_ratio
-- are too heavy to fan out per stylist inside one statement and the
-- whole call trips `statement_timeout` with SQLSTATE 57014
-- ("canceling statement due to statement timeout"). The public RPC
-- then returns HTTP 500 and the frontend receives no comparison rows.
--
-- Change
-- ------
-- Replace both the public RPC and the private debug mirror with a
-- narrower body that only fans out the four cheap KPIs:
--   revenue, guests_per_month, new_clients_per_month,
--   average_client_spend.
--
-- The `stylist_profitability` leg is also dropped: it is already
-- hidden from self/staff view on the frontend (see
-- `SELF_VIEW_HIDDEN_KPI_CODES` in `KpiDashboardPage.tsx`) so it has
-- no UI surface anyway.
--
-- Locked invariants (unchanged)
-- -----------------------------
-- * Function signatures, argument defaults, ownership, grants,
--   STABLE / SECURITY DEFINER / SECURITY INVOKER, and the 12-column
--   return shape are all identical to the previous migration.
-- * Scope resolution + "staff scope only" gate are unchanged.
-- * NULL filter semantics for `MAX` / `AVG` / `cohort_size` are
--   unchanged.
-- * `is_highest` / `is_above_average` still require `cohort_size >= 2`.
--
-- Future work
-- -----------
-- To re-enable the heavier KPIs we need a cached/materialised path —
-- precomputed per-stylist values for the selected month — rather
-- than another per-call fanout. Tracked separately; out of scope for
-- this hotfix.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_stylist_comparisons_live  (auth-enforced)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_stylist_comparisons_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'staff',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code              text,
  period_start          date,
  period_end            date,
  mtd_through           date,
  is_current_open_month boolean,
  staff_member_id       uuid,
  current_value         numeric(18, 4),
  highest_value         numeric(18, 4),
  average_value         numeric(18, 4),
  cohort_size           integer,
  is_highest            boolean,
  is_above_average      boolean
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
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_stylist_comparisons_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  IF v_scope <> 'staff' OR v_staff_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH cohort AS (
    SELECT sm.id AS staff_id
    FROM public.staff_members sm
    WHERE sm.is_active = true
      AND COALESCE(lower(btrim(sm.primary_role)), '') LIKE '%stylist%'
  ),
  per_stylist AS (
    SELECT 'revenue'::text AS kpi_code, c.staff_id, d.value AS v
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_revenue(
      v_period_start, 'staff', NULL, c.staff_id
    ) d

    UNION ALL
    SELECT 'guests_per_month'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_guests_per_month(
      v_period_start, 'staff', NULL, c.staff_id
    ) d

    UNION ALL
    SELECT 'new_clients_per_month'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_new_clients_per_month(
      v_period_start, 'staff', NULL, c.staff_id
    ) d

    UNION ALL
    SELECT 'average_client_spend'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_average_client_spend(
      v_period_start, 'staff', NULL, c.staff_id
    ) d
  ),
  agg AS (
    SELECT
      p.kpi_code,
      MAX(p.v) FILTER (WHERE p.v IS NOT NULL)            AS highest,
      AVG(p.v) FILTER (WHERE p.v IS NOT NULL)            AS avg_v,
      (COUNT(*) FILTER (WHERE p.v IS NOT NULL))::integer AS cohort_count,
      MAX(p.v) FILTER (WHERE p.staff_id = v_staff_id)    AS current_v
    FROM per_stylist p
    GROUP BY p.kpi_code
  )
  SELECT
    a.kpi_code                              AS kpi_code,
    v_period_start                          AS period_start,
    v_period_end                            AS period_end,
    v_mtd_through                           AS mtd_through,
    v_is_current                            AS is_current_open_month,
    v_staff_id                              AS staff_member_id,
    a.current_v::numeric(18, 4)             AS current_value,
    a.highest::numeric(18, 4)               AS highest_value,
    a.avg_v::numeric(18, 4)                 AS average_value,
    a.cohort_count                          AS cohort_size,
    (
      a.cohort_count >= 2
      AND a.current_v IS NOT NULL
      AND a.highest   IS NOT NULL
      AND a.current_v >= a.highest
    )                                       AS is_highest,
    (
      a.cohort_count >= 2
      AND a.current_v IS NOT NULL
      AND a.avg_v     IS NOT NULL
      AND a.current_v >  a.avg_v
    )                                       AS is_above_average
  FROM agg a
  ORDER BY a.kpi_code;
END;
$fn$;

ALTER FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) IS
'Live stylist comparison layer for the staff/self KPI dashboard. Narrowed on 2026-04 to the lightweight KPI subset (revenue, guests_per_month, new_clients_per_month, average_client_spend) after the full nine-KPI fanout tripped statement_timeout at real-world cohort sizes. Returns one row per supported KPI with current_value (caller), highest_value, average_value across the active stylist cohort (primary_role ILIKE %stylist%), plus is_highest / is_above_average flags. Returns zero rows when resolved scope is not staff. NULL values are excluded from MAX/AVG. is_highest / is_above_average require cohort_size >= 2.';


-- ---------------------------------------------------------------------
-- 2. private.debug_kpi_stylist_comparisons  (validation only)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.debug_kpi_stylist_comparisons(
  p_period_start    date,
  p_scope           text DEFAULT 'staff',
  p_location_id     uuid DEFAULT NULL,
  p_staff_member_id uuid DEFAULT NULL
)
RETURNS TABLE (
  kpi_code              text,
  period_start          date,
  period_end            date,
  mtd_through           date,
  is_current_open_month boolean,
  staff_member_id       uuid,
  current_value         numeric(18, 4),
  highest_value         numeric(18, 4),
  average_value         numeric(18, 4),
  cohort_size           integer,
  is_highest            boolean,
  is_above_average      boolean
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
  v_scope        text := COALESCE(NULLIF(btrim(p_scope), ''), 'staff');
  v_staff_id     uuid := p_staff_member_id;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION 'debug_kpi_stylist_comparisons: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope <> 'staff' THEN
    RAISE EXCEPTION 'debug_kpi_stylist_comparisons: only staff scope is supported, got %', v_scope
      USING ERRCODE = '22023';
  END IF;
  IF v_staff_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_stylist_comparisons: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  RETURN QUERY
  WITH cohort AS (
    SELECT sm.id AS staff_id
    FROM public.staff_members sm
    WHERE sm.is_active = true
      AND COALESCE(lower(btrim(sm.primary_role)), '') LIKE '%stylist%'
  ),
  per_stylist AS (
    SELECT 'revenue'::text AS kpi_code, c.staff_id, d.value AS v
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_revenue(
      v_period_start, 'staff', NULL, c.staff_id
    ) d
    UNION ALL
    SELECT 'guests_per_month'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_guests_per_month(
      v_period_start, 'staff', NULL, c.staff_id
    ) d
    UNION ALL
    SELECT 'new_clients_per_month'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_new_clients_per_month(
      v_period_start, 'staff', NULL, c.staff_id
    ) d
    UNION ALL
    SELECT 'average_client_spend'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_average_client_spend(
      v_period_start, 'staff', NULL, c.staff_id
    ) d
  ),
  agg AS (
    SELECT
      p.kpi_code,
      MAX(p.v) FILTER (WHERE p.v IS NOT NULL)            AS highest,
      AVG(p.v) FILTER (WHERE p.v IS NOT NULL)            AS avg_v,
      (COUNT(*) FILTER (WHERE p.v IS NOT NULL))::integer AS cohort_count,
      MAX(p.v) FILTER (WHERE p.staff_id = v_staff_id)    AS current_v
    FROM per_stylist p
    GROUP BY p.kpi_code
  )
  SELECT
    a.kpi_code                  AS kpi_code,
    v_period_start              AS period_start,
    v_period_end                AS period_end,
    v_mtd_through               AS mtd_through,
    v_is_current                AS is_current_open_month,
    v_staff_id                  AS staff_member_id,
    a.current_v::numeric(18, 4) AS current_value,
    a.highest::numeric(18, 4)   AS highest_value,
    a.avg_v::numeric(18, 4)     AS average_value,
    a.cohort_count              AS cohort_size,
    (
      a.cohort_count >= 2
      AND a.current_v IS NOT NULL
      AND a.highest   IS NOT NULL
      AND a.current_v >= a.highest
    )                           AS is_highest,
    (
      a.cohort_count >= 2
      AND a.current_v IS NOT NULL
      AND a.avg_v     IS NOT NULL
      AND a.current_v >  a.avg_v
    )                           AS is_above_average
  FROM agg a
  ORDER BY a.kpi_code;
END;
$fn$;

ALTER FUNCTION private.debug_kpi_stylist_comparisons(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_stylist_comparisons(date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_stylist_comparisons(date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_stylist_comparisons_live without the kpi_resolve_scope auth wrapper. Narrowed on 2026-04 to the same lightweight subset (revenue, guests_per_month, new_clients_per_month, average_client_spend). Same row shape. Drop when validation is complete.';
