-- Rebuild RPC: function-level statement_timeout (fixes nested timeout under pool/role defaults),
-- RAISE LOG timing for Takapuna-scale diagnostics, and supporting btree indexes.

CREATE INDEX IF NOT EXISTS idx_sales_transactions_import_batch_id
  ON public.sales_transactions (import_batch_id);

CREATE INDEX IF NOT EXISTS idx_raw_sales_import_rows_import_batch_id
  ON public.raw_sales_import_rows (import_batch_id);

CREATE INDEX IF NOT EXISTS idx_sales_import_batches_source_location_id
  ON public.sales_import_batches (source_name, location_id, id);

CREATE OR REPLACE FUNCTION public.rebuild_sales_daily_sheets_reporting_data(
  p_location_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, private, pg_temp
SET statement_timeout TO '0'
AS $$
DECLARE
  v_batch_id uuid;
  v_deleted bigint;
  v_loaded integer;
  v_batches_rebuilt integer := 0;
  v_total_deleted bigint := 0;
  v_total_created bigint := 0;
  v_rebuilt_at timestamptz := clock_timestamp();
  v_start timestamptz;
  v_step timestamptz;
  v_batch_count bigint;
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  v_start := clock_timestamp();
  RAISE LOG
    'rebuild_sales_daily_sheets_reporting_data step=rebuild_start location_id=% start_at=%',
    p_location_id,
    v_start;

  PERFORM set_config('statement_timeout', '0', true);

  SELECT count(*)::bigint
  INTO v_batch_count
  FROM public.sales_import_batches b
  WHERE b.source_name = 'SalesDailySheets'
    AND (p_location_id IS NULL OR b.location_id = p_location_id);

  RAISE LOG
    'rebuild_sales_daily_sheets_reporting_data step=batch_discovery batch_count=% elapsed_ms=%',
    v_batch_count,
    round(extract(epoch FROM (clock_timestamp() - v_start)) * 1000.0)::bigint;

  FOR v_batch_id IN
    SELECT b.id
    FROM public.sales_import_batches b
    WHERE b.source_name = 'SalesDailySheets'
      AND (p_location_id IS NULL OR b.location_id = p_location_id)
    ORDER BY b.created_at NULLS LAST, b.id
  LOOP
    RAISE LOG
      'rebuild_sales_daily_sheets_reporting_data step=batch_start batch_id=% elapsed_ms_since_rebuild_start=%',
      v_batch_id,
      round(extract(epoch FROM (clock_timestamp() - v_start)) * 1000.0)::bigint;

    v_step := clock_timestamp();
    DELETE FROM public.sales_transactions st
    WHERE st.import_batch_id = v_batch_id;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;
    v_total_deleted := v_total_deleted + v_deleted;
    RAISE LOG
      'rebuild_sales_daily_sheets_reporting_data step=batch_delete_sales_transactions batch_id=% rows_deleted=% elapsed_ms=%',
      v_batch_id,
      v_deleted,
      round(extract(epoch FROM (clock_timestamp() - v_step)) * 1000.0)::bigint;

    v_step := clock_timestamp();
    v_loaded := public.load_raw_sales_rows_to_transactions(v_batch_id);
    RAISE LOG
      'rebuild_sales_daily_sheets_reporting_data step=batch_load_raw_sales_rows_to_transactions batch_id=% rows_loaded=% elapsed_ms=%',
      v_batch_id,
      v_loaded,
      round(extract(epoch FROM (clock_timestamp() - v_step)) * 1000.0)::bigint;

    v_step := clock_timestamp();
    UPDATE public.sales_import_batches b
    SET
      status = 'processed',
      row_count = v_loaded,
      updated_at = now()
    WHERE b.id = v_batch_id;
    RAISE LOG
      'rebuild_sales_daily_sheets_reporting_data step=batch_update_sales_import_batches batch_id=% elapsed_ms=%',
      v_batch_id,
      round(extract(epoch FROM (clock_timestamp() - v_step)) * 1000.0)::bigint;

    v_total_created := v_total_created + v_loaded::bigint;
    v_batches_rebuilt := v_batches_rebuilt + 1;
  END LOOP;

  RAISE LOG
    'rebuild_sales_daily_sheets_reporting_data step=rebuild_complete batches_rebuilt=% transactions_deleted=% transactions_created=% elapsed_ms_since_rebuild_start=%',
    v_batches_rebuilt,
    v_total_deleted,
    v_total_created,
    round(extract(epoch FROM (clock_timestamp() - v_start)) * 1000.0)::bigint;

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
  'Elevated only: deletes sales_transactions for SalesDailySheets sales_import_batches (optional location filter), then reloads from raw_sales_import_rows via load_raw_sales_rows_to_transactions. Does not remove raw rows, staged rows, or batch metadata. Function-level SET statement_timeout=0 plus set_config; RAISE LOG timings per step.';

REVOKE ALL ON FUNCTION public.rebuild_sales_daily_sheets_reporting_data(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_sales_daily_sheets_reporting_data(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.rebuild_sales_daily_sheets_reporting_data(uuid) FROM anon;

ANALYZE public.sales_transactions;
ANALYZE public.raw_sales_import_rows;
ANALYZE public.sales_import_batches;
