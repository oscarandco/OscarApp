-- =====================================================================
-- KPI drilldown: enrich retention branches with first/last visit dates.
--
-- Scope
-- -----
-- Additive change to `private.debug_kpi_drilldown` only:
--
--   * client_retention_6m
--   * client_retention_12m
--   * new_client_retention_6m
--   * new_client_retention_12m
--
-- Each retention row now carries two extra keys in its `raw_payload`:
--
--   first_visit_in_window  -- earliest in-scope sale_date for this client
--                             inside the KPI's relevant window
--   last_visit_in_window   -- latest   in-scope sale_date for this client
--                             inside the KPI's relevant window
--
-- The frontend drilldown table reads these to render the
-- "Date of first visit" / "Date of last visit" columns for retention
-- KPIs. All other branches, the public wrapper, and the KPI math are
-- unchanged.
-- =====================================================================


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
        COUNT(*)         AS v_count,
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
  --
  -- Added here (additive, vs the 20260501420000 migration):
  --   * `all_visits` CTE computes first/last sale_date across the full
  --     trailing window for each in-scope client.
  --   * `first_visit_in_window` + `last_visit_in_window` keys exposed in
  --     `raw_payload` so the UI can render "Date of first visit" /
  --     "Date of last visit" columns.
  --
  -- Retention cohort math is unchanged.
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
    ),
    all_visits AS (
      SELECT
        s.client_key,
        min(s.sale_date) AS first_visit_in_window,
        max(s.sale_date) AS last_visit_in_window
      FROM in_scope s
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
        'normalised_name',       b.client_key,
        'sample_raw_name',       b.sample_raw,
        'first_visit_in_base',   b.first_visit_in_base,
        'first_return',          r.first_return,
        'return_visit_count',    COALESCE(r.return_visit_count, 0),
        'retained',              (r.client_key IS NOT NULL),
        'first_half_start',      v_first_half_start,
        'first_half_end',        v_first_half_end,
        'second_half_start',     v_second_half_start,
        'second_half_end',       v_second_half_end,
        'first_visit_in_window', av.first_visit_in_window,
        'last_visit_in_window',  av.last_visit_in_window
      )                                                                    AS raw_payload
    FROM base_cohort b
    LEFT JOIN second_half_visits r ON r.client_key = b.client_key
    LEFT JOIN all_visits         av ON av.client_key = b.client_key
    ORDER BY (r.client_key IS NOT NULL) DESC, b.client_key;
    RETURN;
  END IF;

  -- ---------------- new_client_retention_6m / 12m ----------------
  --
  -- Added here (additive, vs the 20260501420000 migration):
  --   * `all_visits` CTE computes first/last sale_date across the
  --     relevant window (base month through observed return window)
  --     for each in-scope client.
  --   * `first_visit_in_window` + `last_visit_in_window` keys exposed in
  --     `raw_payload` so the UI can render "Date of first visit" /
  --     "Date of last visit" columns.
  --
  -- Cohort math + windowing are unchanged.
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
    ),
    all_visits AS (
      SELECT
        public.normalise_customer_name(e.customer_name) AS client_key,
        min(e.sale_date)                                AS first_visit_in_window,
        max(e.sale_date)                                AS last_visit_in_window
      FROM public.v_sales_transactions_enriched e
      WHERE e.sale_date BETWEEN v_period_start AND v_return_end_obs
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
        'is_return_window_complete',  (current_date >= v_return_end_full),
        'first_visit_in_window',      av.first_visit_in_window,
        'last_visit_in_window',       av.last_visit_in_window
      )                                                                     AS raw_payload
    FROM cohort c
    LEFT JOIN return_visits r  ON r.client_key  = c.client_key
    LEFT JOIN all_visits    av ON av.client_key = c.client_key
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
'DEBUG / VALIDATION ONLY. Raw-row drilldown for each supported KPI. Mirrors the filters / windows / scope rules of the matching live KPI RPC. Retention branches additionally expose first_visit_in_window / last_visit_in_window in raw_payload so the UI can render first/last visit date columns. Not exposed via PostgREST. Drop when the v1 KPI validation phase is over.';
