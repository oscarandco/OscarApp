-- KPI Revenue source label clarity update.
--
-- The Revenue KPI (`public.get_kpi_revenue_live`) already excludes both
-- voucher rows (via `public.is_voucher_sale_row`) and internal rows
-- (via `commission_owner_candidate_name <> 'internal'`).
--
-- The user-facing `source` string returned by the RPC and rendered by
-- the KPI detail panel previously only called out vouchers:
--
--     public.v_sales_transactions_enriched (price_ex_gst, vouchers excluded)
--
-- This migration updates that string to clearly state that internal rows
-- are also excluded. Calculations, filters, and grants are unchanged —
-- only the `source` literal and the function comment are touched.

CREATE OR REPLACE FUNCTION public.get_kpi_revenue_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'business',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
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
  v_period_end   date;
  v_mtd_through  date;
  v_is_current   boolean;
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
  v_total        numeric(18, 4);
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_revenue_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  -- Voucher rows are excluded: they're customer prepayments /
  -- liabilities, not salon revenue. The exclusion happens via
  -- public.is_voucher_sale_row(...) so the rule lives in one place.
  -- Internal rows are excluded via the commission_owner_candidate_name
  -- check below.
  SELECT COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4)
    INTO v_total
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = v_period_start
    AND e.sale_date  <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND NOT public.is_voucher_sale_row(
      e.raw_product_type, e.product_type_actual,
      e.product_type_short, e.commission_product_service
    )
    AND (
      v_scope = 'business'
      OR (v_scope = 'location' AND e.location_id = v_loc_id)
      OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = v_staff_id)
    );

  RETURN QUERY
  SELECT
    'revenue'::text                                                  AS kpi_code,
    v_scope                                                          AS scope_type,
    v_loc_id                                                         AS location_id,
    v_staff_id                                                       AS staff_member_id,
    v_period_start                                                   AS period_start,
    v_period_end                                                     AS period_end,
    v_mtd_through                                                    AS mtd_through,
    v_is_current                                                     AS is_current_open_month,
    v_total                                                          AS value,
    v_total                                                          AS value_numerator,
    NULL::numeric(18, 4)                                             AS value_denominator,
    'Sales ex GST, excluding vouchers and internal rows'::text       AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) IS
'Live revenue (ex GST) KPI. Excludes voucher rows (public.is_voucher_sale_row, customer prepayments / liabilities) and internal rows (commission_owner_candidate_name = ''internal''). Stylist/assistant callers are silently restricted to their own staff scope.';
