-- Batch-by-batch rebuild: list eligible import batches, rebuild one batch per RPC (PostgREST-friendly).

CREATE OR REPLACE FUNCTION public.list_sales_daily_sheets_rebuild_batches(
  p_location_id uuid DEFAULT NULL
)
RETURNS TABLE (
  batch_id uuid,
  location_id uuid,
  location_name text,
  source_file_name text,
  raw_rows bigint,
  existing_transactions bigint,
  created_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, private, pg_temp
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN QUERY
  SELECT
    b.id,
    b.location_id,
    coalesce(
      nullif(trim(l.name), ''),
      nullif(trim(l.code), ''),
      b.location_id::text
    ) AS location_name,
    coalesce(b.source_file_name, '')::text AS source_file_name,
    (
      SELECT count(*)::bigint
      FROM public.raw_sales_import_rows rr
      WHERE rr.import_batch_id = b.id
    ) AS raw_rows,
    (
      SELECT count(*)::bigint
      FROM public.sales_transactions st
      WHERE st.import_batch_id = b.id
    ) AS existing_transactions,
    b.created_at
  FROM public.sales_import_batches b
  LEFT JOIN public.locations l ON l.id = b.location_id
  WHERE b.source_name = 'SalesDailySheets'
    AND (p_location_id IS NULL OR b.location_id = p_location_id)
  ORDER BY
    coalesce(
      nullif(trim(l.name), ''),
      nullif(trim(l.code), ''),
      b.location_id::text
    ),
    b.created_at NULLS LAST,
    b.id;
END;
$$;

ALTER FUNCTION public.list_sales_daily_sheets_rebuild_batches(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.list_sales_daily_sheets_rebuild_batches(uuid) IS
  'Elevated only: lists SalesDailySheets sales_import_batches for optional location, with raw/transaction counts, ordered for sequential rebuild.';

REVOKE ALL ON FUNCTION public.list_sales_daily_sheets_rebuild_batches(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_sales_daily_sheets_rebuild_batches(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.list_sales_daily_sheets_rebuild_batches(uuid) FROM anon;


CREATE OR REPLACE FUNCTION public.rebuild_sales_daily_sheets_reporting_batch(
  p_batch_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, private, pg_temp
SET statement_timeout TO '0'
AS $$
DECLARE
  v_deleted bigint;
  v_loaded integer;
  v_location_id uuid;
  v_location_name text;
  v_source_file text;
  v_rebuilt_at timestamptz := clock_timestamp();
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  PERFORM set_config('statement_timeout', '0', true);

  SELECT
    b.location_id,
    coalesce(
      nullif(trim(l.name), ''),
      nullif(trim(l.code), ''),
      b.location_id::text
    ),
    coalesce(b.source_file_name, '')::text
  INTO v_location_id, v_location_name, v_source_file
  FROM public.sales_import_batches b
  LEFT JOIN public.locations l ON l.id = b.location_id
  WHERE b.id = p_batch_id
    AND b.source_name = 'SalesDailySheets';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'batch not found or not a SalesDailySheets import batch: %', p_batch_id;
  END IF;

  DELETE FROM public.sales_transactions st
  WHERE st.import_batch_id = p_batch_id;
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  v_loaded := public.load_raw_sales_rows_to_transactions(p_batch_id);

  UPDATE public.sales_import_batches b
  SET
    status = 'processed',
    row_count = v_loaded,
    updated_at = now()
  WHERE b.id = p_batch_id;

  RETURN jsonb_build_object(
    'status', 'ok',
    'batch_id', p_batch_id,
    'location_id', v_location_id,
    'location_name', v_location_name,
    'source_file_name', v_source_file,
    'transactions_deleted', v_deleted,
    'transactions_created', v_loaded,
    'rebuilt_at', v_rebuilt_at
  );
END;
$$;

ALTER FUNCTION public.rebuild_sales_daily_sheets_reporting_batch(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.rebuild_sales_daily_sheets_reporting_batch(uuid) IS
  'Elevated only: deletes sales_transactions for one SalesDailySheets batch, reloads via load_raw_sales_rows_to_transactions, updates batch row.';

REVOKE ALL ON FUNCTION public.rebuild_sales_daily_sheets_reporting_batch(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rebuild_sales_daily_sheets_reporting_batch(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.rebuild_sales_daily_sheets_reporting_batch(uuid) FROM anon;
