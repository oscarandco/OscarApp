-- =====================================================================
-- KPI drilldown RPC: expose the underlying rows that explain each KPI.
--
-- Purpose
-- -------
-- The KPI dashboard shows a single aggregated number per KPI (via the
-- snapshot dispatcher). For diagnostic / inspection, the UI needs the
-- actual rows that feed each KPI. This migration adds a single
-- auth-enforced diagnostic RPC plus its SQL-editor mirror:
--
--   * public.get_kpi_drilldown_live   (auth-enforced)
--   * private.debug_kpi_drilldown     (validation only)
--
-- The snapshot dispatcher (public.get_kpi_snapshot_live) is unchanged.
-- No KPI math changes. All branches mirror the exact same filters /
-- windows / scope rules used by their matching live KPI RPC.
--
-- Return shape  (generic, frontend-friendly)
-- ------------------------------------------
--   kpi_code        text     -- echoed from p_kpi_code
--   row_type        text     -- e.g. 'sale_line', 'guest', 'new_client',
--                            --      'retained', 'not_retained', ...
--   primary_label   text     -- human-readable identity (guest name / staff name)
--   secondary_label text     -- supporting label (stylist / role / 'Retained'...)
--   metric_value    numeric  -- the main numeric carried by the row
--                            -- (price, visit_count, revenue, ...)
--   metric_value_2  numeric  -- optional 2nd metric (total spend, FTE, flag, ...)
--   event_date      date     -- the most meaningful date for the row
--   location_id     uuid     -- if applicable
--   staff_member_id uuid     -- if applicable
--   raw_payload     jsonb    -- explicit diagnostic bag
--
-- Scope resolution
-- ----------------
-- Delegated to private.kpi_resolve_scope once inside the public
-- wrapper. Stylist / assistant callers are auto-restricted to their
-- own staff scope (consistent with every other live KPI RPC). The
-- public wrapper then calls the private helper with the already-
-- resolved triple so both functions share one body without running
-- the resolve step twice.
--
-- KPIs supported in this migration
-- --------------------------------
--   revenue, guests_per_month, new_clients_per_month,
--   average_client_spend, client_frequency,
--   client_retention_6m, client_retention_12m,
--   new_client_retention_6m, new_client_retention_12m,
--   assistant_utilisation_ratio, stylist_profitability.
--
-- Unknown KPI codes raise SQLSTATE 22023.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. private.debug_kpi_drilldown  (validation only; no auth wrapper)
--
-- SECURITY INVOKER and not exposed via PostgREST grants, same pattern
-- as every other private.debug_kpi_* helper.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.debug_kpi_drilldown(
  p_kpi_code        text,
  p_period_start    date,
  p_scope           text DEFAULT 'business',
  p_location_id     uuid DEFAULT NULL,
  p_staff_member_id uuid DEFAULT NULL
)
RETURNS TABLE (
  kpi_code         text,
  row_type         text,
  primary_label    text,
  secondary_label  text,
  metric_value     numeric,
  metric_value_2   numeric,
  event_date       date,
  location_id      uuid,
  staff_member_id  uuid,
  raw_payload      jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start      date := COALESCE(p_period_start, date_trunc('month', current_date)::date);
  v_period_end        date;
  v_mtd_through       date;
  v_scope             text := COALESCE(NULLIF(btrim(p_scope), ''), 'business');
  v_loc_id            uuid := p_location_id;
  v_staff_id          uuid := p_staff_member_id;
  v_kpi               text := lower(btrim(p_kpi_code));
  v_window_start      date;
  v_window_end        date;
  v_first_half_start  date;
  v_first_half_end    date;
  v_second_half_start date;
  v_second_half_end   date;
  v_return_start      date;
  v_return_end_full   date;
  v_return_end_obs    date;
BEGIN
  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION 'debug_kpi_drilldown: p_period_start must be the 1st of a month, got %',
      v_period_start USING ERRCODE = '22023';
  END IF;
  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION 'debug_kpi_drilldown: invalid scope %', v_scope USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND v_loc_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_drilldown: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'staff' AND v_staff_id IS NULL THEN
    RAISE EXCEPTION 'debug_kpi_drilldown: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_mtd_through := LEAST(v_period_end, current_date);

  -- ---------------- revenue ----------------
  IF v_kpi = 'revenue' THEN
    RETURN QUERY
    SELECT
      'revenue'::text                                                            AS kpi_code,
      'sale_line'::text                                                          AS row_type,
      COALESCE(NULLIF(btrim(e.customer_name), ''), '—')::text                    AS primary_label,
      COALESCE(NULLIF(btrim(e.commission_owner_candidate_name), ''), '—')::text  AS secondary_label,
      e.price_ex_gst::numeric                                                    AS metric_value,
      NULL::numeric                                                              AS metric_value_2,
      e.sale_date                                                                AS event_date,
      e.location_id                                                              AS location_id,
      e.commission_owner_candidate_id                                            AS staff_member_id,
      jsonb_build_object(
        'customer_name',                    e.customer_name,
        'sale_date',                        e.sale_date,
        'month_start',                      e.month_start,
        'price_ex_gst',                     e.price_ex_gst,
        'location_id',                      e.location_id,
        'commission_owner_candidate_id',    e.commission_owner_candidate_id,
        'commission_owner_candidate_name',  e.commission_owner_candidate_name,
        'assistant_redirect_candidate',     e.assistant_redirect_candidate
      )                                                                          AS raw_payload
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = v_period_start
      AND e.sale_date  <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND e.location_id                    = v_loc_id)
        OR (v_scope = 'staff'    AND e.commission_owner_candidate_id  = v_staff_id)
      )
    ORDER BY e.sale_date DESC, e.price_ex_gst DESC NULLS LAST;
    RETURN;
  END IF;

  -- ---------------- guests_per_month ----------------
  IF v_kpi = 'guests_per_month' THEN
    RETURN QUERY
    WITH in_scope AS (
      SELECT
        public.normalise_customer_name(e.customer_name) AS client_key,
        e.customer_name                                 AS raw_name,
        e.sale_date,
        e.location_id                                   AS loc_id,
        e.price_ex_gst
      FROM public.v_sales_transactions_enriched e
      WHERE e.month_start = v_period_start
        AND e.sale_date  <= v_mtd_through
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND public.normalise_customer_name(e.customer_name) IS NOT NULL
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id                    = v_loc_id)
          OR (v_scope = 'staff'    AND e.commission_owner_candidate_id  = v_staff_id)
        )
    ),
    agg AS (
      SELECT
        s.client_key,
        min(s.raw_name)                          AS sample_raw,
        min(s.sale_date)                         AS first_visit,
        max(s.sale_date)                         AS last_visit,
        COUNT(DISTINCT (s.sale_date, s.loc_id))  AS v_count,
        COALESCE(SUM(s.price_ex_gst), 0)         AS total_ex_gst,
        COUNT(*)                                 AS line_count
      FROM in_scope s
      GROUP BY s.client_key
    )
    SELECT
      'guests_per_month'::text                                      AS kpi_code,
      'guest'::text                                                 AS row_type,
      a.client_key::text                                            AS primary_label,
      COALESCE(NULLIF(btrim(a.sample_raw), ''), a.client_key)::text AS secondary_label,
      a.v_count::numeric                                            AS metric_value,
      a.total_ex_gst::numeric                                       AS metric_value_2,
      a.first_visit                                                 AS event_date,
      NULL::uuid                                                    AS location_id,
      NULL::uuid                                                    AS staff_member_id,
      jsonb_build_object(
        'normalised_name', a.client_key,
        'sample_raw_name', a.sample_raw,
        'first_visit',     a.first_visit,
        'last_visit',      a.last_visit,
        'visit_count',     a.v_count,
        'line_count',      a.line_count,
        'total_ex_gst',    a.total_ex_gst
      )                                                             AS raw_payload
    FROM agg a
    ORDER BY a.total_ex_gst DESC NULLS LAST, a.client_key;
    RETURN;
  END IF;

  -- ---------------- new_clients_per_month ----------------
  IF v_kpi = 'new_clients_per_month' THEN
    RETURN QUERY
    WITH in_scope AS (
      SELECT
        public.normalise_customer_name(e.customer_name) AS client_key,
        e.customer_name                                 AS raw_name,
        e.sale_date,
        e.location_id                                   AS loc_id,
        e.price_ex_gst
      FROM public.v_sales_transactions_enriched e
      WHERE e.month_start = v_period_start
        AND e.sale_date  <= v_mtd_through
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND public.normalise_customer_name(e.customer_name) IS NOT NULL
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id                    = v_loc_id)
          OR (v_scope = 'staff'    AND e.commission_owner_candidate_id  = v_staff_id)
        )
    ),
    agg AS (
      SELECT
        s.client_key,
        min(s.raw_name)                          AS sample_raw,
        min(s.sale_date)                         AS first_visit_in_period,
        COUNT(DISTINCT (s.sale_date, s.loc_id))  AS v_count,
        COALESCE(SUM(s.price_ex_gst), 0)         AS total_ex_gst
      FROM in_scope s
      GROUP BY s.client_key
    ),
    new_clients AS (
      SELECT a.*
      FROM agg a
      WHERE NOT EXISTS (
        SELECT 1 FROM public.v_sales_transactions_enriched e2
        WHERE e2.sale_date < v_period_start
          AND public.normalise_customer_name(e2.customer_name) = a.client_key
      )
    )
    SELECT
      'new_clients_per_month'::text                                   AS kpi_code,
      'new_client'::text                                              AS row_type,
      nc.client_key::text                                             AS primary_label,
      COALESCE(NULLIF(btrim(nc.sample_raw), ''), nc.client_key)::text AS secondary_label,
      nc.v_count::numeric                                             AS metric_value,
      nc.total_ex_gst::numeric                                        AS metric_value_2,
      nc.first_visit_in_period                                        AS event_date,
      NULL::uuid                                                      AS location_id,
      NULL::uuid                                                      AS staff_member_id,
      jsonb_build_object(
        'normalised_name',       nc.client_key,
        'sample_raw_name',       nc.sample_raw,
        'first_visit_in_period', nc.first_visit_in_period,
        'visit_count',           nc.v_count,
        'total_ex_gst',          nc.total_ex_gst
      )                                                               AS raw_payload
    FROM new_clients nc
    ORDER BY nc.first_visit_in_period, nc.client_key;
    RETURN;
  END IF;

  -- ---------------- average_client_spend ----------------
  -- Same universe as guests_per_month, ordered by total spend desc.
  IF v_kpi = 'average_client_spend' THEN
    RETURN QUERY
    WITH in_scope AS (
      SELECT
        public.normalise_customer_name(e.customer_name) AS client_key,
        e.customer_name                                 AS raw_name,
        e.sale_date,
        e.location_id                                   AS loc_id,
        e.price_ex_gst
      FROM public.v_sales_transactions_enriched e
      WHERE e.month_start = v_period_start
        AND e.sale_date  <= v_mtd_through
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND public.normalise_customer_name(e.customer_name) IS NOT NULL
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id                    = v_loc_id)
          OR (v_scope = 'staff'    AND e.commission_owner_candidate_id  = v_staff_id)
        )
    ),
    agg AS (
      SELECT
        s.client_key,
        min(s.raw_name)                          AS sample_raw,
        min(s.sale_date)                         AS first_visit,
        max(s.sale_date)                         AS last_visit,
        COUNT(DISTINCT (s.sale_date, s.loc_id))  AS v_count,
        COALESCE(SUM(s.price_ex_gst), 0)         AS total_ex_gst
      FROM in_scope s
      GROUP BY s.client_key
    )
    SELECT
      'average_client_spend'::text                                  AS kpi_code,
      'guest_spend'::text                                           AS row_type,
      a.client_key::text                                            AS primary_label,
      COALESCE(NULLIF(btrim(a.sample_raw), ''), a.client_key)::text AS secondary_label,
      a.total_ex_gst::numeric                                       AS metric_value,
      a.v_count::numeric                                            AS metric_value_2,
      a.last_visit                                                  AS event_date,
      NULL::uuid                                                    AS location_id,
      NULL::uuid                                                    AS staff_member_id,
      jsonb_build_object(
        'normalised_name', a.client_key,
        'sample_raw_name', a.sample_raw,
        'first_visit',     a.first_visit,
        'last_visit',      a.last_visit,
        'visit_count',     a.v_count,
        'total_ex_gst',    a.total_ex_gst
      )                                                             AS raw_payload
    FROM agg a
    ORDER BY a.total_ex_gst DESC NULLS LAST, a.client_key;
    RETURN;
  END IF;

  -- ---------------- client_frequency (trailing 12m) ----------------
  IF v_kpi = 'client_frequency' THEN
    v_window_end   := v_mtd_through;
    v_window_start := (v_window_end + interval '1 day' - interval '12 months')::date;

    RETURN QUERY
    WITH in_scope AS (
      SELECT
        public.normalise_customer_name(e.customer_name) AS client_key,
        e.customer_name                                 AS raw_name,
        e.sale_date,
        e.location_id                                   AS loc_id
      FROM public.v_sales_transactions_enriched e
      WHERE e.sale_date BETWEEN v_window_start AND v_window_end
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND public.normalise_customer_name(e.customer_name) IS NOT NULL
        AND public.normalise_customer_name(e.customer_name) <> ''
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id                    = v_loc_id)
          OR (v_scope = 'staff'    AND e.commission_owner_candidate_id  = v_staff_id)
        )
    ),
    visits AS (
      SELECT DISTINCT s.client_key, s.sale_date, s.loc_id FROM in_scope s
    ),
    agg AS (
      SELECT
        v.client_key,
        (SELECT min(i.raw_name) FROM in_scope i WHERE i.client_key = v.client_key) AS sample_raw,
        COUNT(*)        AS v_count,
        min(v.sale_date) AS first_visit,
        max(v.sale_date) AS last_visit
      FROM visits v
      GROUP BY v.client_key
    )
    SELECT
      'client_frequency'::text                                      AS kpi_code,
      'client_trailing_12m'::text                                   AS row_type,
      a.client_key::text                                            AS primary_label,
      COALESCE(NULLIF(btrim(a.sample_raw), ''), a.client_key)::text AS secondary_label,
      a.v_count::numeric                                            AS metric_value,
      NULL::numeric                                                 AS metric_value_2,
      a.last_visit                                                  AS event_date,
      NULL::uuid                                                    AS location_id,
      NULL::uuid                                                    AS staff_member_id,
      jsonb_build_object(
        'normalised_name', a.client_key,
        'sample_raw_name', a.sample_raw,
        'visit_count',     a.v_count,
        'first_visit',     a.first_visit,
        'last_visit',      a.last_visit,
        'window_start',    v_window_start,
        'window_end',      v_window_end
      )                                                             AS raw_payload
    FROM agg a
    ORDER BY a.v_count DESC, a.client_key;
    RETURN;
  END IF;

  -- ---------------- client_retention_6m / 12m (split-window) ----------------
  IF v_kpi IN ('client_retention_6m', 'client_retention_12m') THEN
    IF v_kpi = 'client_retention_6m' THEN
      v_first_half_start  := (v_period_start - interval '5 months')::date;
      v_first_half_end    := ((v_period_start - interval '2 months')::date - 1);
      v_second_half_start := (v_period_start - interval '2 months')::date;
    ELSE
      v_first_half_start  := (v_period_start - interval '11 months')::date;
      v_first_half_end    := ((v_period_start - interval '5 months')::date - 1);
      v_second_half_start := (v_period_start - interval '5 months')::date;
    END IF;
    v_second_half_end := v_mtd_through;

    RETURN QUERY
    WITH in_scope AS (
      SELECT
        public.normalise_customer_name(e.customer_name) AS client_key,
        e.customer_name                                 AS raw_name,
        e.sale_date
      FROM public.v_sales_transactions_enriched e
      WHERE e.sale_date BETWEEN v_first_half_start AND v_second_half_end
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND public.normalise_customer_name(e.customer_name) IS NOT NULL
        AND public.normalise_customer_name(e.customer_name) <> ''
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id                    = v_loc_id)
          OR (v_scope = 'staff'    AND e.commission_owner_candidate_id  = v_staff_id)
        )
    ),
    base_cohort AS (
      SELECT
        s.client_key,
        min(s.raw_name)  AS sample_raw,
        min(s.sale_date) AS first_visit_in_base
      FROM in_scope s
      WHERE s.sale_date BETWEEN v_first_half_start AND v_first_half_end
      GROUP BY s.client_key
    ),
    second_half_visits AS (
      SELECT
        s.client_key,
        min(s.sale_date) AS first_return,
        COUNT(*)         AS return_visit_count
      FROM in_scope s
      WHERE s.sale_date BETWEEN v_second_half_start AND v_second_half_end
      GROUP BY s.client_key
    )
    SELECT
      v_kpi::text                                                          AS kpi_code,
      CASE WHEN r.client_key IS NOT NULL THEN 'retained' ELSE 'not_retained' END::text
                                                                           AS row_type,
      b.client_key::text                                                   AS primary_label,
      CASE WHEN r.client_key IS NOT NULL THEN 'Retained' ELSE 'Not retained' END::text
                                                                           AS secondary_label,
      COALESCE(r.return_visit_count, 0)::numeric                           AS metric_value,
      NULL::numeric                                                        AS metric_value_2,
      b.first_visit_in_base                                                AS event_date,
      NULL::uuid                                                           AS location_id,
      NULL::uuid                                                           AS staff_member_id,
      jsonb_build_object(
        'normalised_name',     b.client_key,
        'sample_raw_name',     b.sample_raw,
        'first_visit_in_base', b.first_visit_in_base,
        'first_return',        r.first_return,
        'return_visit_count',  COALESCE(r.return_visit_count, 0),
        'retained',            (r.client_key IS NOT NULL),
        'first_half_start',    v_first_half_start,
        'first_half_end',      v_first_half_end,
        'second_half_start',   v_second_half_start,
        'second_half_end',     v_second_half_end
      )                                                                    AS raw_payload
    FROM base_cohort b
    LEFT JOIN second_half_visits r ON r.client_key = b.client_key
    ORDER BY (r.client_key IS NOT NULL) DESC, b.client_key;
    RETURN;
  END IF;

  -- ---------------- new_client_retention_6m / 12m ----------------
  IF v_kpi IN ('new_client_retention_6m', 'new_client_retention_12m') THEN
    v_return_start := (v_period_start + interval '1 month')::date;
    IF v_kpi = 'new_client_retention_6m' THEN
      v_return_end_full := (v_period_start + interval '7 months'  - interval '1 day')::date;
    ELSE
      v_return_end_full := (v_period_start + interval '13 months' - interval '1 day')::date;
    END IF;
    v_return_end_obs := LEAST(v_return_end_full, current_date);

    RETURN QUERY
    WITH in_period_guests AS (
      SELECT
        public.normalise_customer_name(e.customer_name) AS client_key,
        min(e.customer_name)                            AS sample_raw,
        min(e.sale_date)                                AS first_visit_in_base
      FROM public.v_sales_transactions_enriched e
      WHERE e.month_start = v_period_start
        AND e.sale_date  <= v_mtd_through
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND public.normalise_customer_name(e.customer_name) IS NOT NULL
        AND public.normalise_customer_name(e.customer_name) <> ''
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id                    = v_loc_id)
          OR (v_scope = 'staff'    AND e.commission_owner_candidate_id  = v_staff_id)
        )
      GROUP BY public.normalise_customer_name(e.customer_name)
    ),
    cohort AS (
      SELECT g.*
      FROM in_period_guests g
      WHERE NOT EXISTS (
        SELECT 1 FROM public.v_sales_transactions_enriched e2
        WHERE e2.sale_date < v_period_start
          AND public.normalise_customer_name(e2.customer_name) = g.client_key
      )
    ),
    return_visits AS (
      SELECT
        public.normalise_customer_name(e.customer_name) AS client_key,
        min(e.sale_date)                                AS first_return,
        COUNT(*)                                        AS return_visit_count
      FROM public.v_sales_transactions_enriched e
      WHERE e.sale_date BETWEEN v_return_start AND v_return_end_obs
        AND v_return_end_obs >= v_return_start
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND public.normalise_customer_name(e.customer_name) IS NOT NULL
        AND public.normalise_customer_name(e.customer_name) <> ''
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id                    = v_loc_id)
          OR (v_scope = 'staff'    AND e.commission_owner_candidate_id  = v_staff_id)
        )
      GROUP BY public.normalise_customer_name(e.customer_name)
    )
    SELECT
      v_kpi::text                                                           AS kpi_code,
      CASE WHEN r.client_key IS NOT NULL THEN 'retained' ELSE 'not_retained' END::text
                                                                            AS row_type,
      c.client_key::text                                                    AS primary_label,
      CASE WHEN r.client_key IS NOT NULL THEN 'Retained' ELSE 'Not retained' END::text
                                                                            AS secondary_label,
      COALESCE(r.return_visit_count, 0)::numeric                            AS metric_value,
      NULL::numeric                                                         AS metric_value_2,
      c.first_visit_in_base                                                 AS event_date,
      NULL::uuid                                                            AS location_id,
      NULL::uuid                                                            AS staff_member_id,
      jsonb_build_object(
        'normalised_name',            c.client_key,
        'sample_raw_name',            c.sample_raw,
        'first_visit_in_base',        c.first_visit_in_base,
        'first_return',               r.first_return,
        'return_visit_count',         COALESCE(r.return_visit_count, 0),
        'retained',                   (r.client_key IS NOT NULL),
        'return_window_start',        v_return_start,
        'return_window_end_full',     v_return_end_full,
        'return_window_end_observed', v_return_end_obs,
        'is_return_window_complete',  (current_date >= v_return_end_full)
      )                                                                     AS raw_payload
    FROM cohort c
    LEFT JOIN return_visits r ON r.client_key = c.client_key
    ORDER BY (r.client_key IS NOT NULL) DESC, c.client_key;
    RETURN;
  END IF;

  -- ---------------- assistant_utilisation_ratio ----------------
  IF v_kpi = 'assistant_utilisation_ratio' THEN
    RETURN QUERY
    SELECT
      'assistant_utilisation_ratio'::text                                        AS kpi_code,
      CASE WHEN e.assistant_redirect_candidate THEN 'assistant_helped'
           ELSE 'stylist_only' END::text                                         AS row_type,
      COALESCE(NULLIF(btrim(e.customer_name), ''), '—')::text                    AS primary_label,
      COALESCE(NULLIF(btrim(e.commission_owner_candidate_name), ''), '—')::text  AS secondary_label,
      e.price_ex_gst::numeric                                                    AS metric_value,
      CASE WHEN e.assistant_redirect_candidate THEN 1::numeric
           ELSE 0::numeric END                                                   AS metric_value_2,
      e.sale_date                                                                AS event_date,
      e.location_id                                                              AS location_id,
      e.commission_owner_candidate_id                                            AS staff_member_id,
      jsonb_build_object(
        'customer_name',                    e.customer_name,
        'sale_date',                        e.sale_date,
        'price_ex_gst',                     e.price_ex_gst,
        'location_id',                      e.location_id,
        'commission_owner_candidate_id',    e.commission_owner_candidate_id,
        'commission_owner_candidate_name',  e.commission_owner_candidate_name,
        'assistant_redirect_candidate',     e.assistant_redirect_candidate
      )                                                                          AS raw_payload
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = v_period_start
      AND e.sale_date  <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND (
        v_scope = 'business'
        OR (v_scope = 'location' AND e.location_id                    = v_loc_id)
        OR (v_scope = 'staff'    AND e.commission_owner_candidate_id  = v_staff_id)
      )
    ORDER BY e.sale_date DESC, e.price_ex_gst DESC NULLS LAST;
    RETURN;
  END IF;

  -- ---------------- stylist_profitability ----------------
  -- One row per contributing stylist id with (revenue, fte) components.
  -- At staff scope: one row (the requested stylist). At location /
  -- business scope: every stylist who produced an in-scope sale is
  -- surfaced; row_type tags whether they are eligible for the rollup
  -- (primary_role like %stylist% AND fte > 0) so the panel shows both
  -- contributors and near-contributors.
  IF v_kpi = 'stylist_profitability' THEN
    RETURN QUERY
    WITH stylist_sales AS (
      SELECT
        e.commission_owner_candidate_id                   AS sid,
        min(e.commission_owner_candidate_name)            AS sname,
        SUM(e.price_ex_gst)                               AS revenue,
        COUNT(*)                                          AS line_count,
        min(e.sale_date)                                  AS first_sale,
        max(e.sale_date)                                  AS last_sale
      FROM public.v_sales_transactions_enriched e
      WHERE e.month_start = v_period_start
        AND e.sale_date  <= v_mtd_through
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND e.commission_owner_candidate_id IS NOT NULL
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id                    = v_loc_id)
          OR (v_scope = 'staff'    AND e.commission_owner_candidate_id  = v_staff_id)
        )
      GROUP BY e.commission_owner_candidate_id
    ),
    with_staff AS (
      SELECT
        ss.sid,
        COALESCE(NULLIF(btrim(sm.display_name), ''),
                 NULLIF(btrim(sm.full_name),    ''),
                 NULLIF(btrim(ss.sname),        ''),
                 '—')                               AS name,
        sm.primary_role                             AS primary_role,
        sm.is_active                                AS is_active,
        sm.fte::numeric                             AS fte,
        ss.revenue::numeric                         AS revenue,
        ss.line_count,
        ss.first_sale,
        ss.last_sale
      FROM stylist_sales ss
      LEFT JOIN public.staff_members sm ON sm.id = ss.sid
    )
    SELECT
      'stylist_profitability'::text                                        AS kpi_code,
      CASE
        WHEN v_scope = 'staff' THEN 'staff_stylist'
        WHEN COALESCE(lower(btrim(w.primary_role)), '') LIKE '%stylist%'
          AND w.fte IS NOT NULL AND w.fte > 0
            THEN 'eligible_stylist'
        ELSE 'ineligible_stylist'
      END::text                                                            AS row_type,
      w.name::text                                                         AS primary_label,
      COALESCE(NULLIF(btrim(w.primary_role), ''), '—')::text                AS secondary_label,
      w.revenue                                                            AS metric_value,
      w.fte                                                                AS metric_value_2,
      w.last_sale                                                          AS event_date,
      NULL::uuid                                                           AS location_id,
      w.sid                                                                AS staff_member_id,
      jsonb_build_object(
        'staff_member_id', w.sid,
        'name',            w.name,
        'primary_role',    w.primary_role,
        'is_active',       w.is_active,
        'fte',             w.fte,
        'revenue_ex_gst',  w.revenue,
        'line_count',      w.line_count,
        'first_sale',      w.first_sale,
        'last_sale',       w.last_sale,
        'eligible_for_rollup',
          CASE
            WHEN v_scope = 'staff' THEN NULL
            ELSE (
              COALESCE(lower(btrim(w.primary_role)), '') LIKE '%stylist%'
              AND w.fte IS NOT NULL AND w.fte > 0
            )
          END
      )                                                                    AS raw_payload
    FROM with_staff w
    ORDER BY w.revenue DESC NULLS LAST, w.name;
    RETURN;
  END IF;

  RAISE EXCEPTION
    'debug_kpi_drilldown: unknown p_kpi_code %; supported: revenue, guests_per_month, new_clients_per_month, average_client_spend, client_frequency, client_retention_6m, client_retention_12m, new_client_retention_6m, new_client_retention_12m, assistant_utilisation_ratio, stylist_profitability',
    v_kpi
    USING ERRCODE = '22023';
END;
$fn$;

ALTER FUNCTION private.debug_kpi_drilldown(text, date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.debug_kpi_drilldown(text, date, text, uuid, uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.debug_kpi_drilldown(text, date, text, uuid, uuid) IS
'DEBUG / VALIDATION ONLY. Raw-row drilldown for each supported KPI. Mirrors the filters / windows / scope rules of the matching live KPI RPC. Not exposed via PostgREST. Drop when the v1 KPI validation phase is over.';


-- ---------------------------------------------------------------------
-- 2. public.get_kpi_drilldown_live  (auth-enforced)
--
-- Resolves scope via private.kpi_resolve_scope (stylist/assistant auto-
-- restricted to their own staff scope) and forwards the already-
-- resolved triple to private.debug_kpi_drilldown. This keeps all KPI
-- branch bodies in one place without duplicating the large IF/ELSIF
-- block in two functions.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_kpi_drilldown_live(
  p_kpi_code        text,
  p_period_start    date DEFAULT NULL,
  p_scope           text DEFAULT 'business',
  p_location_id     uuid DEFAULT NULL,
  p_staff_member_id uuid DEFAULT NULL
)
RETURNS TABLE (
  kpi_code         text,
  row_type         text,
  primary_label    text,
  secondary_label  text,
  metric_value     numeric,
  metric_value_2   numeric,
  event_date       date,
  location_id      uuid,
  staff_member_id  uuid,
  raw_payload      jsonb
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date;
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_drilldown_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  RETURN QUERY
  SELECT *
  FROM private.debug_kpi_drilldown(
    p_kpi_code,
    v_period_start,
    v_scope,
    v_loc_id,
    v_staff_id
  );
END;
$fn$;

ALTER FUNCTION public.get_kpi_drilldown_live(text, date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_drilldown_live(text, date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_drilldown_live(text, date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_drilldown_live(text, date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_drilldown_live(text, date, text, uuid, uuid) IS
'Live KPI drilldown: returns the underlying rows that feed the requested KPI for the requested (period, scope). Auth + scope resolution delegate to private.kpi_resolve_scope. Row bodies delegate to private.debug_kpi_drilldown so the per-KPI filter logic lives in exactly one place. Supported KPIs: revenue, guests_per_month, new_clients_per_month, average_client_spend, client_frequency, client_retention_6m, client_retention_12m, new_client_retention_6m, new_client_retention_12m, assistant_utilisation_ratio, stylist_profitability.';
