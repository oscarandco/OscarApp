CREATE OR REPLACE FUNCTION public.delete_all_sales_daily_sheets_import_data()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $$
DECLARE
  n_tx bigint;
  n_raw bigint;
  n_batch bigint;
  n_staged bigint;
  n_sheet bigint;
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  PERFORM set_config('statement_timeout', '0', true);

  DELETE FROM public.sales_transactions st
  USING public.sales_import_batches b
  WHERE st.import_batch_id = b.id
    AND b.source_name = 'SalesDailySheets';
  GET DIAGNOSTICS n_tx = ROW_COUNT;

  DELETE FROM public.raw_sales_import_rows rr
  USING public.sales_import_batches b
  WHERE rr.import_batch_id = b.id
    AND b.source_name = 'SalesDailySheets';
  GET DIAGNOSTICS n_raw = ROW_COUNT;

  DELETE FROM public.sales_import_batches b
  WHERE b.source_name = 'SalesDailySheets';
  GET DIAGNOSTICS n_batch = ROW_COUNT;

  SELECT count(*)::bigint INTO n_staged FROM public.sales_daily_sheets_staged_rows;
  TRUNCATE TABLE public.sales_daily_sheets_staged_rows;

  SELECT count(*)::bigint INTO n_sheet FROM public.sales_daily_sheets_import_batches;
  TRUNCATE TABLE public.sales_daily_sheets_import_batches;

  RETURN jsonb_build_object(
    'sales_transactions_deleted', n_tx,
    'raw_sales_import_rows_deleted', n_raw,
    'sales_import_batches_deleted', n_batch,
    'sales_daily_sheets_staged_rows_deleted', n_staged,
    'sales_daily_sheets_import_batches_deleted', n_sheet
  );
END;
$$;

ALTER FUNCTION public.delete_all_sales_daily_sheets_import_data() OWNER TO postgres;

COMMENT ON FUNCTION public.delete_all_sales_daily_sheets_import_data() IS
  'Destructive reset: removes all Sales Daily Sheets import data (elevated users only). Idempotent. Uses statement_timeout=0 and TRUNCATE for SDS-only tables.';