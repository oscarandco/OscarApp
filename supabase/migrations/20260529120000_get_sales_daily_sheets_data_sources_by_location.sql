-- My Sales / Sales Summary: data coverage metadata, one row per location.
--
-- New function with a distinct name and return type from
-- `get_sales_daily_sheets_data_sources()` (per-batch shape). Aggregates
-- current `sales_transactions` for SalesDailySheets batches by `location_id`.
--
-- Frontend display metadata uses this RPC; the legacy function is left
-- unchanged for compatibility.

CREATE OR REPLACE FUNCTION public.get_sales_daily_sheets_data_sources_by_location()
RETURNS TABLE (
  location_id uuid,
  location_code text,
  location_name text,
  row_count bigint,
  min_sale_date date,
  max_sale_date date
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    st.location_id,
    max(l.code)::text AS location_code,
    max(l.name)::text AS location_name,
    count(*)::bigint AS row_count,
    min(st.sale_date) AS min_sale_date,
    max(st.sale_date) AS max_sale_date
  FROM public.sales_transactions st
  INNER JOIN public.sales_import_batches b ON b.id = st.import_batch_id
  INNER JOIN public.locations l ON l.id = st.location_id
  WHERE b.source_name = 'SalesDailySheets'
    AND st.location_id IS NOT NULL
  GROUP BY st.location_id
  ORDER BY max(l.name) NULLS LAST;
$$;

ALTER FUNCTION public.get_sales_daily_sheets_data_sources_by_location() OWNER TO postgres;

COMMENT ON FUNCTION public.get_sales_daily_sheets_data_sources_by_location() IS
  'Display metadata: one row per location — count and min/max sale_date of current sales_transactions tied to SalesDailySheets import batches.';

REVOKE ALL ON FUNCTION public.get_sales_daily_sheets_data_sources_by_location() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_sales_daily_sheets_data_sources_by_location() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_sales_daily_sheets_data_sources_by_location() TO service_role;
