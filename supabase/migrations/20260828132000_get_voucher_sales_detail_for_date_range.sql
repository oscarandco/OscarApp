-- Sales Summary: voucher sale line detail for disclosure modal/drawer.
-- Same population and access gate as get_voucher_sales_ex_gst_by_location_for_date_range.

CREATE OR REPLACE FUNCTION public.get_voucher_sales_detail_for_date_range(
  p_sale_date_from date,
  p_sale_date_to date,
  p_location_id uuid DEFAULT NULL
)
RETURNS TABLE (
  sale_date date,
  location_id uuid,
  location_name text,
  invoice text,
  customer_name text,
  product_service_name text,
  product_type_short text,
  commission_product_service text,
  price_ex_gst numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT (SELECT private.user_has_page_access('commission_breakdown', 'view')) THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  RETURN QUERY
  SELECT
    st.sale_date,
    st.location_id,
    l.name::text AS location_name,
    st.invoice,
    st.customer_name,
    st.product_service_name,
    st.product_type_short,
    st.commission_product_service,
    st.price_ex_gst
  FROM public.sales_transactions st
  INNER JOIN public.sales_import_batches b ON b.id = st.import_batch_id
  LEFT JOIN public.locations l ON l.id = st.location_id
  WHERE b.source_name = 'SalesDailySheets'
    AND st.location_id IS NOT NULL
    AND st.sale_date >= p_sale_date_from
    AND st.sale_date <= p_sale_date_to
    AND (p_location_id IS NULL OR st.location_id = p_location_id)
    AND (
      lower(trim(coalesce(st.product_type_short, ''))) = 'voucher'
      OR lower(trim(coalesce(st.commission_product_service, ''))) = 'voucher'
    )
  ORDER BY st.sale_date DESC, st.invoice NULLS LAST, st.product_service_name;
END;
$$;

ALTER FUNCTION public.get_voucher_sales_detail_for_date_range(date, date, uuid)
  OWNER TO postgres;

COMMENT ON FUNCTION public.get_voucher_sales_detail_for_date_range(date, date, uuid) IS
  'Sales Summary voucher disclosure detail. Gated by commission_breakdown page access (view+). Returns voucher sales_transactions rows for sale_date in [from, to], optionally filtered to one location_id.';

REVOKE ALL ON FUNCTION public.get_voucher_sales_detail_for_date_range(date, date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_voucher_sales_detail_for_date_range(date, date, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_voucher_sales_detail_for_date_range(date, date, uuid) TO service_role;
