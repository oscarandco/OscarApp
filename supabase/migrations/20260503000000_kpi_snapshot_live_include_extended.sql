-- Optional p_include_extended on get_kpi_snapshot_live: when false, skip the
-- five expensive retention/frequency KPIs so the KPI dashboard initial load
-- stays within statement_timeout. Default true preserves full 11-KPI behaviour
-- for callers that omit the parameter.

DROP FUNCTION IF EXISTS public.get_kpi_snapshot_live(date, text, uuid, uuid);

CREATE OR REPLACE FUNCTION public.get_kpi_snapshot_live(
  p_period_start       date,
  p_scope               text DEFAULT 'business',
  p_location_id         uuid DEFAULT NULL,
  p_staff_member_id     uuid DEFAULT NULL,
  p_include_extended    boolean DEFAULT true
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
      'get_kpi_snapshot_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  RETURN QUERY
    SELECT * FROM public.get_kpi_revenue_live(v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_guests_per_month_live(v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_new_clients_per_month_live(v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_average_client_spend_live(v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_assistant_utilisation_ratio_live(v_period_start, v_scope, v_loc_id, v_staff_id)
    UNION ALL
    SELECT * FROM public.get_kpi_stylist_profitability_live(v_period_start, v_scope, v_loc_id, v_staff_id);

  IF p_include_extended THEN
    RETURN QUERY
      SELECT * FROM public.get_kpi_client_frequency_live(v_period_start, v_scope, v_loc_id, v_staff_id)
      UNION ALL
      SELECT * FROM public.get_kpi_client_retention_6m_live(v_period_start, v_scope, v_loc_id, v_staff_id)
      UNION ALL
      SELECT * FROM public.get_kpi_client_retention_12m_live(v_period_start, v_scope, v_loc_id, v_staff_id)
      UNION ALL
      SELECT * FROM public.get_kpi_new_client_retention_6m_live(v_period_start, v_scope, v_loc_id, v_staff_id)
      UNION ALL
      SELECT * FROM public.get_kpi_new_client_retention_12m_live(v_period_start, v_scope, v_loc_id, v_staff_id);
  END IF;
END;
$fn$;

ALTER FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid, boolean) TO service_role;

COMMENT ON FUNCTION public.get_kpi_snapshot_live(date, text, uuid, uuid, boolean) IS
'Live KPI snapshot dispatcher. Returns one row per KPI (locked 12-column shape). When p_include_extended is true (default), returns all 11 KPIs as before. When false, returns only the six core KPIs (revenue through stylist_profitability), skipping client_frequency and all retention variants for fast initial loads.';
