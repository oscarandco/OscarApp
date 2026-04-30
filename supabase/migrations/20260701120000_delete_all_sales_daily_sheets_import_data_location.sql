-- Scoped delete for Sales Daily Sheets: optional p_location_id (NULL = all salons).
-- Replaces delete_all_sales_daily_sheets_import_data (see 20260530120000) with p_location_id param.

DROP FUNCTION IF EXISTS public.delete_all_sales_daily_sheets_import_data();
DROP FUNCTION IF EXISTS public.delete_all_sales_daily_sheets_import_data(uuid);

CREATE OR REPLACE FUNCTION public.delete_all_sales_daily_sheets_import_data(
  p_location_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, private, pg_temp
SET statement_timeout TO '0'
AS $$
DECLARE
  n_tx bigint := 0;
  n_raw bigint := 0;
  n_batch bigint := 0;
  n_staged bigint := 0;
  n_sheet bigint := 0;
  v_del bigint;
  v_deleted_at timestamptz := clock_timestamp();
  v_location_name text;
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_location_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.locations l WHERE l.id = p_location_id
  ) THEN
    RAISE EXCEPTION 'invalid p_location_id';
  END IF;

  v_location_name :=
    CASE
      WHEN p_location_id IS NULL THEN 'All locations'
      ELSE (SELECT coalesce(nullif(trim(l.name), ''), l.code, l.id::text)
            FROM public.locations l
            WHERE l.id = p_location_id)
    END;

  PERFORM set_config('statement_timeout', '0', true);

  CREATE TEMP TABLE tmp_sds_import_batch_ids (
    id uuid PRIMARY KEY
  ) ON COMMIT DROP;

  INSERT INTO tmp_sds_import_batch_ids (id)
  SELECT b.id
  FROM public.sales_import_batches b
  WHERE b.source_name = 'SalesDailySheets'
    AND (p_location_id IS NULL OR b.location_id = p_location_id);

  IF p_location_id IS NOT NULL THEN
    CREATE TEMP TABLE tmp_sheet_batch_ids (
      id uuid PRIMARY KEY
    ) ON COMMIT DROP;

    INSERT INTO tmp_sheet_batch_ids (id)
    SELECT DISTINCT b.id
    FROM public.sales_daily_sheets_import_batches b
    WHERE b.selected_location_id = p_location_id
      OR EXISTS (
        SELECT 1
        FROM public.sales_daily_sheets_staged_rows r
        WHERE r.batch_id = b.id
          AND r.location_id = p_location_id
      )
      OR (
        b.payroll_import_batch_id IS NOT NULL
        AND b.payroll_import_batch_id IN (SELECT t.id FROM tmp_sds_import_batch_ids t)
      );
  END IF;

  LOOP
    DELETE FROM public.sales_transactions st
    WHERE st.id IN (
      SELECT st2.id
      FROM public.sales_transactions st2
      WHERE st2.import_batch_id IN (SELECT t.id FROM tmp_sds_import_batch_ids t)
      LIMIT 25000
    );
    GET DIAGNOSTICS v_del = ROW_COUNT;
    n_tx := n_tx + v_del;
    EXIT WHEN v_del = 0;
  END LOOP;

  LOOP
    DELETE FROM public.raw_sales_import_rows rr
    WHERE rr.id IN (
      SELECT rr2.id
      FROM public.raw_sales_import_rows rr2
      WHERE rr2.import_batch_id IN (SELECT t.id FROM tmp_sds_import_batch_ids t)
      LIMIT 25000
    );
    GET DIAGNOSTICS v_del = ROW_COUNT;
    n_raw := n_raw + v_del;
    EXIT WHEN v_del = 0;
  END LOOP;

  DELETE FROM public.sales_import_batches b
  WHERE b.id IN (SELECT t.id FROM tmp_sds_import_batch_ids t);
  GET DIAGNOSTICS n_batch = ROW_COUNT;

  IF p_location_id IS NULL THEN
    SELECT count(*)::bigint INTO n_staged FROM public.sales_daily_sheets_staged_rows;
    TRUNCATE TABLE public.sales_daily_sheets_staged_rows;

    SELECT count(*)::bigint INTO n_sheet FROM public.sales_daily_sheets_import_batches;
    TRUNCATE TABLE public.sales_daily_sheets_import_batches;
  ELSE
    DELETE FROM public.sales_daily_sheets_staged_rows r
    WHERE r.batch_id IN (SELECT s.id FROM tmp_sheet_batch_ids s);
    GET DIAGNOSTICS n_staged = ROW_COUNT;

    DELETE FROM public.sales_daily_sheets_import_batches b
    WHERE b.id IN (SELECT s.id FROM tmp_sheet_batch_ids s);
    GET DIAGNOSTICS n_sheet = ROW_COUNT;
  END IF;

  RETURN jsonb_build_object(
    'status', 'ok',
    'message',
    CASE
      WHEN p_location_id IS NULL THEN
        format(
          'Deleted Sales Daily Sheets data for all salons (%s transactions, %s raw rows, %s import batches, %s staged rows, %s sheet batches).',
          n_tx,
          n_raw,
          n_batch,
          n_staged,
          n_sheet
        )
      ELSE
        format(
          'Deleted Sales Daily Sheets data for %s only (%s transactions, %s raw rows, %s import batches, %s staged rows, %s sheet batches).',
          v_location_name,
          n_tx,
          n_raw,
          n_batch,
          n_staged,
          n_sheet
        )
    END,
    'location_id', p_location_id,
    'location_name', v_location_name,
    'transactions_deleted', n_tx,
    'raw_rows_deleted', n_raw,
    'sales_import_batches_deleted', n_batch,
    'staged_rows_deleted', n_staged,
    'staged_batches_deleted', n_sheet,
    'deleted_at', v_deleted_at
  );
END;
$$;

ALTER FUNCTION public.delete_all_sales_daily_sheets_import_data(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.delete_all_sales_daily_sheets_import_data(uuid) IS
  'Elevated only: deletes SalesDailySheets sales_transactions, raw_sales_import_rows, and '
  'sales_import_batches. When p_location_id is NULL, TRUNCATEs SDS staging tables for all salons; '
  'when set, deletes only rows/batches for that location (sheet batches via selected_location_id, '
  'staged location_id, or payroll_import_batch_id in the scoped payroll batch set).';

REVOKE ALL ON FUNCTION public.delete_all_sales_daily_sheets_import_data(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_all_sales_daily_sheets_import_data(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.delete_all_sales_daily_sheets_import_data(uuid) FROM anon;
