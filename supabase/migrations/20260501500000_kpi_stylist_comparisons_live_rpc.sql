-- =====================================================================
-- Stylist comparison RPC for the KPI dashboard.
--
-- Purpose
-- -------
-- For the staff/self KPI dashboard view, compute how the requested
-- stylist compares with the rest of the stylist cohort for the same
-- (period, KPI) pair. The result drives a subtle "Highest / Average"
-- note plus a tint on the headline value in the KpiCard. Business
-- and location scopes are explicitly out of scope for this slice.
--
-- Design (deliberately additive and minimal)
-- ------------------------------------------
-- * No new KPI math. The cohort values come from the already-validated
--   `private.debug_kpi_*` helpers via `CROSS JOIN LATERAL`. The math
--   for every supported KPI therefore matches the snapshot dispatcher
--   row-for-row.
-- * Locked to nine KPIs only — exactly the set the product spec calls
--   out as "comparison-eligible". `new_client_retention_6m/12m` are
--   intentionally excluded.
-- * `SECURITY DEFINER` + `private.kpi_resolve_scope` so non-elevated
--   stylists are silently pinned to their own staff scope, the same
--   contract as every other live KPI RPC.
-- * Returns no rows when the resolved scope is not staff. The caller
--   always gets back a stable shape (table with zero or N rows).
-- * Cohort definition reuses the stylist-role rule already established
--   by `stylist_profitability` (`primary_role ILIKE '%stylist%'`) plus
--   `is_active = true`. Assistants, managers, admins, receptionists
--   are excluded.
--
-- Eligibility / null semantics
-- ----------------------------
-- * KPIs that produce NULL because of an unusable denominator (e.g.
--   `client_retention_*` for a stylist with no first-half clients,
--   `client_frequency` for a stylist with no clients in window,
--   `assistant_utilisation_ratio` for a stylist with no eligible
--   sales) are excluded from `MAX(...)` and `AVG(...)` via
--   `FILTER (WHERE v IS NOT NULL)`. They are NOT coerced to zero.
-- * KPIs that legitimately produce zero (revenue, guests, new clients
--   for a stylist with no sales that month) DO contribute to the
--   average. This is intentional — they represent active stylists
--   with a real, comparable measurement of zero for the period.
-- * `is_highest` / `is_above_average` require `cohort_size >= 2`; a
--   single-stylist cohort can't generate a meaningful comparison.
--
-- Row shape
-- ---------
-- One row per supported `kpi_code`:
--   kpi_code              text
--   period_start          date
--   period_end            date
--   mtd_through           date
--   is_current_open_month boolean
--   staff_member_id       uuid     -- the resolved caller staff id
--   current_value         numeric(18,4)
--   highest_value         numeric(18,4)
--   average_value         numeric(18,4)
--   cohort_size           integer  -- # of stylists with non-null values
--   is_highest            boolean
--   is_above_average      boolean
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

  -- Auth + scope resolution (silently collapses non-elevated callers
  -- to their own staff scope; raises 28000 on unauthenticated).
  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  -- Comparison layer is staff/self-only for v1. Any other resolved
  -- scope (or no resolved staff id) returns zero rows.
  IF v_scope <> 'staff' OR v_staff_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH cohort AS (
    -- Stylist-like, currently active staff. Mirrors the role rule
    -- already used by stylist_profitability (primary_role ILIKE
    -- '%stylist%'). Assistants / managers / admins / receptionists
    -- are excluded.
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

    UNION ALL
    SELECT 'client_frequency'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_client_frequency(
      v_period_start, 'staff', NULL, c.staff_id
    ) d

    UNION ALL
    SELECT 'client_retention_6m'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_client_retention_6m(
      v_period_start, 'staff', NULL, c.staff_id
    ) d

    UNION ALL
    SELECT 'client_retention_12m'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_client_retention_12m(
      v_period_start, 'staff', NULL, c.staff_id
    ) d

    UNION ALL
    SELECT 'assistant_utilisation_ratio'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_assistant_utilisation_ratio(
      v_period_start, 'staff', NULL, c.staff_id
    ) d

    UNION ALL
    SELECT 'stylist_profitability'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_stylist_profitability(
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
'Live stylist comparison layer for the staff/self KPI dashboard. Returns one row per supported KPI (revenue, guests_per_month, new_clients_per_month, average_client_spend, client_frequency, client_retention_6m, client_retention_12m, assistant_utilisation_ratio, stylist_profitability) with current_value (caller), highest_value, average_value across the active stylist cohort (primary_role ILIKE %stylist%), plus is_highest / is_above_average flags. Returns zero rows when resolved scope is not staff. NULL values are excluded from MAX/AVG. is_highest / is_above_average require cohort_size >= 2.';


-- ---------------------------------------------------------------------
-- 2. private.debug_kpi_stylist_comparisons  (validation only)
--
-- Identical body to the public RPC but SECURITY INVOKER and without
-- the kpi_resolve_scope auth assertion, so it can be exercised in the
-- Supabase SQL editor (auth.uid() is NULL there). Adds nothing to the
-- output shape — same 12 columns as the public function.
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
    UNION ALL
    SELECT 'client_frequency'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_client_frequency(
      v_period_start, 'staff', NULL, c.staff_id
    ) d
    UNION ALL
    SELECT 'client_retention_6m'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_client_retention_6m(
      v_period_start, 'staff', NULL, c.staff_id
    ) d
    UNION ALL
    SELECT 'client_retention_12m'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_client_retention_12m(
      v_period_start, 'staff', NULL, c.staff_id
    ) d
    UNION ALL
    SELECT 'assistant_utilisation_ratio'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_assistant_utilisation_ratio(
      v_period_start, 'staff', NULL, c.staff_id
    ) d
    UNION ALL
    SELECT 'stylist_profitability'::text, c.staff_id, d.value
    FROM cohort c
    CROSS JOIN LATERAL private.debug_kpi_stylist_profitability(
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
'DEBUG / VALIDATION ONLY. Mirror of public.get_kpi_stylist_comparisons_live without the kpi_resolve_scope auth wrapper. Same row shape. Drop when validation is complete.';
