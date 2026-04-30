-- Rebuild sales_transactions from existing raw_sales_import_rows for
-- Sales Daily Sheets payroll batches (no CSV re-upload). Elevated users only.

CREATE OR REPLACE FUNCTION public.rebuild_sales_daily_sheets_reporting_data(
  p_location_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $$
DECLARE
  v_batch_id uuid;
  v_deleted bigint;
  v_loaded integer;
  v_batches_rebuilt integer := 0;
  v_total_deleted bigint := 0;
  v_total_created bigint := 0;
  v_rebuilt_at timestamptz := clock_timestamp();
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  PERFORM set_config('statement_timeout', '0', true);

  FOR v_batch_id IN
    SELECT b.id
    FROM public.sales_import_batches b
    WHERE b.source_name = 'SalesDailySheets'
      AND (p_location_id IS NULL OR b.location_id = p_location_id)
    ORDER BY b.created_at NULLS LAST, b.id
  LOOP
    DELETE FROM public.sales_transactions st
    WHERE st.import_batch_id = v_batch_id;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_deleted;

    v_loaded := public.load_raw_sales_rows_to_transactions(v_batch_id);

    UPDATE public.sales_import_batches b
    SET
      status = 'processed',
      row_count = v_loaded,
      updated_at = now()
    WHERE b.id = v_batch_id;

    v_total_created := v_total_created + v_loaded::bigint;
    v_batches_rebuilt := v_batches_rebuilt + 1;
  END LOOP;

  RETURN to_jsonb(
    json_build_object(
      'status', 'ok',
      'message',
      CASE
        WHEN v_batches_rebuilt = 0 THEN
          'No SalesDailySheets import batches matched the filter.'
        ELSE
          format('Rebuilt reporting for %s batch(es).', v_batches_rebuilt)
      END,
      'location_id', p_location_id,
      'batches_rebuilt', v_batches_rebuilt,
      'transactions_deleted', v_total_deleted,
      'transactions_created', v_total_created,
      'rebuilt_at', v_rebuilt_at
    )
  );
END;
$$;

ALTER FUNCTION public.rebuild_sales_daily_sheets_reporting_data(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.rebuild_sales_daily_sheets_reporting_data(uuid) IS
  'Elevated only: deletes sales_transactions for SalesDailySheets sales_import_batches (optional location filter), then reloads from raw_sales_import_rows via load_raw_sales_rows_to_transactions. Does not remove raw rows, staged rows, or batch metadata.';

REVOKE ALL ON FUNCTION public.rebuild_sales_daily_sheets_reporting_data(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_sales_daily_sheets_reporting_data(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.rebuild_sales_daily_sheets_reporting_data(uuid) FROM anon;
