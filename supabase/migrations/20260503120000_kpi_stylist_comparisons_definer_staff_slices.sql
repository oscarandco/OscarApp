-- Fix get_kpi_stylist_comparisons_live 500s when called by authenticated users.
--
-- Root cause: the RPC is SECURITY DEFINER (postgres) but fanned out through
-- private.debug_kpi_* helpers that are SECURITY INVOKER. Nested INVOKER
-- routines still execute with the session role's privileges, so
-- authenticated callers lack EXECUTE on private.* and/or hit RLS on
-- v_sales_transactions_enriched when reading other stylists' rows.
--
-- Fix: add postgres-owned SECURITY DEFINER staff-only scalar helpers that
-- duplicate the *staff branch* math from the debug mirrors (same filters),
-- callable only from other definer-owned routines. Swap the comparison RPC
-- (and its private debug mirror) to use those helpers.
--
-- Also restore a 4-argument overload of get_kpi_snapshot_live that forwards
-- to the 5-argument implementation with p_include_extended = true so any
-- PostgREST / SQL callers that omit p_include_extended keep working.

-- ---------------------------------------------------------------------
-- 0. Four staff-slice helpers (SECURITY DEFINER, not exposed to PostgREST)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.kpi_comparison_staff_revenue(
  p_period_start    date,
  p_staff_member_id uuid
)
RETURNS numeric(18, 4)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4)
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = p_period_start
    AND e.sale_date <= LEAST(
      (p_period_start + interval '1 month - 1 day')::date,
      CURRENT_DATE
    )
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND e.commission_owner_candidate_id = p_staff_member_id;
$fn$;

ALTER FUNCTION private.kpi_comparison_staff_revenue(date, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.kpi_comparison_staff_revenue(date, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.kpi_comparison_staff_revenue(date, uuid) IS
'Staff-scope revenue (ex GST) for one stylist/month — same filters as private.debug_kpi_revenue staff branch. SECURITY DEFINER for use only from postgres-owned KPI comparison RPCs.';


CREATE OR REPLACE FUNCTION private.kpi_comparison_staff_guests_per_month(
  p_period_start    date,
  p_staff_member_id uuid
)
RETURNS numeric(18, 4)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT COALESCE(
    COUNT(DISTINCT public.normalise_customer_name(e.customer_name)),
    0
  )::numeric(18, 4)
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = p_period_start
    AND e.sale_date <= LEAST(
      (p_period_start + interval '1 month - 1 day')::date,
      CURRENT_DATE
    )
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND public.normalise_customer_name(e.customer_name) IS NOT NULL
    AND e.commission_owner_candidate_id = p_staff_member_id;
$fn$;

ALTER FUNCTION private.kpi_comparison_staff_guests_per_month(date, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.kpi_comparison_staff_guests_per_month(date, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.kpi_comparison_staff_guests_per_month(date, uuid) IS
'Staff-scope distinct guests for one stylist/month — same filters as private.debug_kpi_guests_per_month staff branch. SECURITY DEFINER for KPI comparison RPCs only.';


CREATE OR REPLACE FUNCTION private.kpi_comparison_staff_new_clients_per_month(
  p_period_start    date,
  p_staff_member_id uuid
)
RETURNS numeric(18, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_mtd_through   date;
  v_new_clients   numeric(18, 4);
BEGIN
  IF p_period_start <> date_trunc('month', p_period_start)::date THEN
    RAISE EXCEPTION
      'kpi_comparison_staff_new_clients_per_month: p_period_start must be month start, got %',
      p_period_start
      USING ERRCODE = '22023';
  END IF;
  IF p_staff_member_id IS NULL THEN
    RAISE EXCEPTION
      'kpi_comparison_staff_new_clients_per_month: p_staff_member_id is required'
      USING ERRCODE = '22023';
  END IF;

  v_mtd_through := LEAST(
    (p_period_start + interval '1 month - 1 day')::date,
    CURRENT_DATE
  );

  WITH in_period_guests AS (
    SELECT DISTINCT public.normalise_customer_name(e.customer_name) AS norm_name
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = p_period_start
      AND e.sale_date <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND public.normalise_customer_name(e.customer_name) IS NOT NULL
      AND e.commission_owner_candidate_id = p_staff_member_id
  ),
  with_first_seen AS (
    SELECT g.norm_name,
           NOT EXISTS (
             SELECT 1 FROM public.v_sales_transactions_enriched e2
             WHERE e2.sale_date < p_period_start
               AND public.normalise_customer_name(e2.customer_name) = g.norm_name
           ) AS is_new
    FROM in_period_guests g
  )
  SELECT (COUNT(*) FILTER (WHERE is_new))::numeric(18, 4)
  INTO v_new_clients
  FROM with_first_seen;

  RETURN COALESCE(v_new_clients, 0::numeric(18, 4));
END;
$fn$;

ALTER FUNCTION private.kpi_comparison_staff_new_clients_per_month(date, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.kpi_comparison_staff_new_clients_per_month(date, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.kpi_comparison_staff_new_clients_per_month(date, uuid) IS
'Staff-scope new clients for one stylist/month — same logic as private.debug_kpi_new_clients_per_month staff branch. SECURITY DEFINER for KPI comparison RPCs only.';


CREATE OR REPLACE FUNCTION private.kpi_comparison_staff_average_client_spend(
  p_period_start    date,
  p_staff_member_id uuid
)
RETURNS numeric(18, 4)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_mtd_through date;
  v_revenue     numeric(18, 4);
  v_guests      numeric(18, 4);
BEGIN
  IF p_period_start <> date_trunc('month', p_period_start)::date THEN
    RAISE EXCEPTION
      'kpi_comparison_staff_average_client_spend: p_period_start must be month start, got %',
      p_period_start
      USING ERRCODE = '22023';
  END IF;
  IF p_staff_member_id IS NULL THEN
    RAISE EXCEPTION
      'kpi_comparison_staff_average_client_spend: p_staff_member_id is required'
      USING ERRCODE = '22023';
  END IF;

  v_mtd_through := LEAST(
    (p_period_start + interval '1 month - 1 day')::date,
    CURRENT_DATE
  );

  SELECT
    COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4),
    COUNT(DISTINCT public.normalise_customer_name(e.customer_name))::numeric(18, 4)
  INTO v_revenue, v_guests
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = p_period_start
    AND e.sale_date <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND e.commission_owner_candidate_id = p_staff_member_id;

  IF v_guests > 0 THEN
    RETURN (v_revenue / v_guests)::numeric(18, 4);
  END IF;
  RETURN NULL::numeric(18, 4);
END;
$fn$;

ALTER FUNCTION private.kpi_comparison_staff_average_client_spend(date, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.kpi_comparison_staff_average_client_spend(date, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.kpi_comparison_staff_average_client_spend(date, uuid) IS
'Staff-scope average client spend for one stylist/month — same logic as private.debug_kpi_average_client_spend staff branch. SECURITY DEFINER for KPI comparison RPCs only.';


-- ---------------------------------------------------------------------
-- 1. public.get_kpi_stylist_comparisons_live  (swap laterals)
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
    SELECT 'revenue'::text AS kpi_code, c.staff_id, d.v
    FROM cohort c
    CROSS JOIN LATERAL (
      SELECT private.kpi_comparison_staff_revenue(v_period_start, c.staff_id) AS v
    ) d

    UNION ALL
    SELECT 'guests_per_month'::text, c.staff_id, d.v
    FROM cohort c
    CROSS JOIN LATERAL (
      SELECT private.kpi_comparison_staff_guests_per_month(v_period_start, c.staff_id) AS v
    ) d

    UNION ALL
    SELECT 'new_clients_per_month'::text, c.staff_id, d.v
    FROM cohort c
    CROSS JOIN LATERAL (
      SELECT private.kpi_comparison_staff_new_clients_per_month(v_period_start, c.staff_id) AS v
    ) d

    UNION ALL
    SELECT 'average_client_spend'::text, c.staff_id, d.v
    FROM cohort c
    CROSS JOIN LATERAL (
      SELECT private.kpi_comparison_staff_average_client_spend(v_period_start, c.staff_id) AS v
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


-- ---------------------------------------------------------------------
-- 2. private.debug_kpi_stylist_comparisons  (validation mirror)
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
    SELECT 'revenue'::text AS kpi_code, c.staff_id, d.v
    FROM cohort c
    CROSS JOIN LATERAL (
      SELECT private.kpi_comparison_staff_revenue(v_period_start, c.staff_id) AS v
    ) d
    UNION ALL
    SELECT 'guests_per_month'::text, c.staff_id, d.v
    FROM cohort c
    CROSS JOIN LATERAL (
      SELECT private.kpi_comparison_staff_guests_per_month(v_period_start, c.staff_id) AS v
    ) d
    UNION ALL
    SELECT 'new_clients_per_month'::text, c.staff_id, d.v
    FROM cohort c
    CROSS JOIN LATERAL (
      SELECT private.kpi_comparison_staff_new_clients_per_month(v_period_start, c.staff_id) AS v
    ) d
    UNION ALL
    SELECT 'average_client_spend'::text, c.staff_id, d.v
    FROM cohort c
    CROSS JOIN LATERAL (
      SELECT private.kpi_comparison_staff_average_client_spend(v_period_start, c.staff_id) AS v
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


-- ---------------------------------------------------------------------
-- 3. Four-arg snapshot overload (forwards to full snapshot, extended=true)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_snapshot_live(
  p_period_start       date,
  p_scope               text DEFAULT 'business',
  p_location_id       uuid DEFAULT NULL,
  p_staff_member_id   uuid DEFAULT NULL
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
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $wrap$
  SELECT *
  FROM public.get_kpi_snapshot_live(
    p_period_start,
    p_scope,
    p_location_id,
    p_staff_member_id,
    true
  );
$wrap$;

ALTER FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid) IS
'Compatibility overload: same rows as get_kpi_snapshot_live(..., p_include_extended true). Use the 5-argument form to request a fast core-only snapshot (p_include_extended false).';
