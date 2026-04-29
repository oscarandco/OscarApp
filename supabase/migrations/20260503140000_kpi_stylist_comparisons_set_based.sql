-- Set-based rewrite of public.get_kpi_stylist_comparisons_live.
--
-- Replaces per-stylist CROSS JOIN LATERAL calls to private.kpi_comparison_staff_*
-- (one scan of v_sales_transactions_enriched per stylist per KPI) with:
--   * one cohort list (active stylists)
--   * one in-month slice of v_sales_transactions_enriched for cohort commission owners
--   * grouped revenue + guests + derived average
--   * new_clients via distinct (staff_id, norm_name) in-period, anti-joined to prior
--     appearances with a single NOT EXISTS pattern (business-wide history, same as
--     get_kpi_new_clients_per_month_live — not internal-filtered on the prior leg)
--   * same outer agg / is_highest / is_above_average as before
--
-- private.kpi_comparison_staff_* helpers are left in place for ad-hoc use but are no
-- longer referenced from this RPC.

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
  month_e AS (
    SELECT
      e.commission_owner_candidate_id AS staff_id,
      e.price_ex_gst,
      e.customer_name
    FROM public.v_sales_transactions_enriched e
    INNER JOIN cohort c ON c.staff_id = e.commission_owner_candidate_id
    WHERE e.month_start = v_period_start
      AND e.sale_date <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  rev AS (
    SELECT
      me.staff_id,
      COALESCE(SUM(me.price_ex_gst), 0)::numeric(18, 4) AS v
    FROM month_e me
    GROUP BY me.staff_id
  ),
  gst AS (
    SELECT
      me.staff_id,
      COUNT(DISTINCT public.normalise_customer_name(me.customer_name))::numeric(18, 4) AS v
    FROM month_e me
    WHERE public.normalise_customer_name(me.customer_name) IS NOT NULL
    GROUP BY me.staff_id
  ),
  cohort_metrics AS (
    SELECT
      c.staff_id,
      COALESCE(r.v, 0::numeric(18, 4)) AS revenue,
      COALESCE(g.v, 0::numeric(18, 4)) AS guests,
      CASE
        WHEN COALESCE(g.v, 0::numeric(18, 4)) > 0 THEN
          (COALESCE(r.v, 0::numeric(18, 4)) / g.v)::numeric(18, 4)
        ELSE NULL::numeric(18, 4)
      END AS avg_spend
    FROM cohort c
    LEFT JOIN rev r ON r.staff_id = c.staff_id
    LEFT JOIN gst g ON g.staff_id = c.staff_id
  ),
  month_norms AS (
    SELECT DISTINCT
      me.staff_id,
      public.normalise_customer_name(me.customer_name) AS norm_name
    FROM month_e me
    WHERE public.normalise_customer_name(me.customer_name) IS NOT NULL
  ),
  newc AS (
    SELECT
      mn.staff_id,
      (COUNT(*)::numeric(18, 4)) AS v
    FROM month_norms mn
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_period_start
        AND public.normalise_customer_name(e2.customer_name) = mn.norm_name
    )
    GROUP BY mn.staff_id
  ),
  per_stylist AS (
    SELECT 'revenue'::text AS kpi_code, cm.staff_id, cm.revenue AS v
    FROM cohort_metrics cm
    UNION ALL
    SELECT 'guests_per_month'::text, cm.staff_id, cm.guests
    FROM cohort_metrics cm
    UNION ALL
    SELECT 'new_clients_per_month'::text, c.staff_id, COALESCE(n.v, 0::numeric(18, 4))
    FROM cohort c
    LEFT JOIN newc n ON n.staff_id = c.staff_id
    UNION ALL
    SELECT 'average_client_spend'::text, cm.staff_id, cm.avg_spend
    FROM cohort_metrics cm
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
'Live stylist comparison for staff/self KPI cards. Set-based: one in-month slice of v_sales_transactions_enriched for the active stylist cohort, grouped metrics (revenue, guests, new clients, average spend), then cohort high/avg vs caller. Prior-sale check for new clients is business-wide and not internal-filtered, matching get_kpi_new_clients_per_month_live.';
