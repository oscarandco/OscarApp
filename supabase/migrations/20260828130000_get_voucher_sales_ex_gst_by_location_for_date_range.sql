-- Sales Summary voucher disclosure: sum voucher sales ex GST from raw
-- sales_transactions (SalesDailySheets batches), not payroll lines.
-- Voucher rows are excluded upstream from v_admin_payroll_lines_weekly.

CREATE OR REPLACE FUNCTION public.get_voucher_sales_ex_gst_by_location_for_date_range(
  p_sale_date_from date,
  p_sale_date_to date
)
RETURNS TABLE (
  location_id uuid,
  voucher_sales_ex_gst numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT public.fn_is_admin_or_manager() THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  RETURN QUERY
  SELECT
    st.location_id,
    round(sum(coalesce(st.price_ex_gst, 0::numeric)), 2) AS voucher_sales_ex_gst
  FROM public.sales_transactions st
  INNER JOIN public.sales_import_batches b ON b.id = st.import_batch_id
  WHERE b.source_name = 'SalesDailySheets'
    AND st.location_id IS NOT NULL
    AND st.sale_date >= p_sale_date_from
    AND st.sale_date <= p_sale_date_to
    AND (
      lower(trim(coalesce(st.product_type_short, ''))) = 'voucher'
      OR lower(trim(coalesce(st.commission_product_service, ''))) = 'voucher'
    )
  GROUP BY st.location_id
  ORDER BY st.location_id;
END;
$$;

ALTER FUNCTION public.get_voucher_sales_ex_gst_by_location_for_date_range(date, date)
  OWNER TO postgres;

COMMENT ON FUNCTION public.get_voucher_sales_ex_gst_by_location_for_date_range(date, date) IS
  'Sales Summary voucher disclosure only. Returns voucher price_ex_gst summed by location for sale_date in [from, to] from SalesDailySheets-backed sales_transactions. Does not affect payroll or commission totals.';

REVOKE ALL ON FUNCTION public.get_voucher_sales_ex_gst_by_location_for_date_range(date, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_voucher_sales_ex_gst_by_location_for_date_range(date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_voucher_sales_ex_gst_by_location_for_date_range(date, date) TO service_role;
