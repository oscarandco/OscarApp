-- My Sales page: data source metadata RPC.
--
-- Returns one row per active SalesDailySheets `sales_import_batches` row,
-- with the source filename, location, row count, and oldest/newest sale
-- date. The apply pipeline keeps a single SalesDailySheets batch per
-- location (location-scoped replacement), so this typically yields one
-- row per active salon location.
--
-- Used by `PayrollSummaryPage` to display the "Data source N" line and
-- to derive the per-location sales tile labels. Aggregate, non-personal
-- metadata, so granted to all authenticated users (any role that can
-- already reach the My Sales page).

CREATE OR REPLACE FUNCTION public.get_sales_daily_sheets_data_sources()
RETURNS TABLE (
  batch_id uuid,
  location_id uuid,
  location_code text,
  location_name text,
  source_file_name text,
  row_count bigint,
  first_sale_date date,
  last_sale_date date,
  imported_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    b.id AS batch_id,
    b.location_id,
    l.code AS location_code,
    l.name AS location_name,
    coalesce(
      nullif(btrim(b.source_file_name), ''),
      'Unknown source file'
    ) AS source_file_name,
    coalesce(t.row_count, 0::bigint) AS row_count,
    t.first_sale_date,
    t.last_sale_date,
    b.imported_at
  FROM public.sales_import_batches b
  LEFT JOIN public.locations l ON l.id = b.location_id
  LEFT JOIN LATERAL (
    SELECT
      count(*)::bigint AS row_count,
      min(st.sale_date) AS first_sale_date,
      max(st.sale_date) AS last_sale_date
    FROM public.sales_transactions st
    WHERE st.import_batch_id = b.id
  ) t ON true
  WHERE b.source_name = 'SalesDailySheets'
  ORDER BY l.name NULLS LAST, b.imported_at DESC;
$$;

ALTER FUNCTION public.get_sales_daily_sheets_data_sources() OWNER TO postgres;

COMMENT ON FUNCTION public.get_sales_daily_sheets_data_sources() IS
  'My Sales page metadata: one row per active SalesDailySheets sales_import_batches row, with source_file_name, location, row_count, first_sale_date, last_sale_date.';

REVOKE ALL ON FUNCTION public.get_sales_daily_sheets_data_sources() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_sales_daily_sheets_data_sources() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_sales_daily_sheets_data_sources() TO service_role;
