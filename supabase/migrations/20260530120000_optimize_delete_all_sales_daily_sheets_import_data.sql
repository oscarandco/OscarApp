-- Admin "Delete all Sales Daily Sheets records": avoid statement timeout when
-- many date-scoped SDS batches exist (large sales_transactions / raw_sales rows).
--
-- Changes:
-- 1) Function-level SET statement_timeout = 0 (same pattern as apply RPCs).
-- 2) One temp table of SDS sales_import_batches ids — no repeated scans of
--    sales_import_batches inside huge DELETEs.
-- 3) Chunked DELETEs on sales_transactions and raw_sales_import_rows.
-- 4) Index (source_name, id) on sales_import_batches to speed filling the temp set.
-- Child tables first, SDS batches last; TRUNCATE for SDS-only staging tables.

CREATE INDEX IF NOT EXISTS idx_sales_import_batches_source_name_id
  ON public.sales_import_batches (source_name, id);

CREATE OR REPLACE FUNCTION public.delete_all_sales_daily_sheets_import_data()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO public, private, pg_temp
SET statement_timeout TO '0'
AS $$
DECLARE
  n_tx bigint := 0;
  n_raw bigint := 0;
  n_batch bigint;
  n_staged bigint;
  n_sheet bigint;
  v_del bigint;
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  PERFORM set_config('statement_timeout', '0', true);

  CREATE TEMP TABLE tmp_sds_import_batch_ids (
    id uuid PRIMARY KEY
  ) ON COMMIT DROP;

  INSERT INTO tmp_sds_import_batch_ids (id)
  SELECT b.id
  FROM public.sales_import_batches b
  WHERE b.source_name = 'SalesDailySheets';

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
  'Destructive reset: removes all Sales Daily Sheets import data (elevated users only). '
  'Idempotent. Uses statement_timeout=0, temp SDS batch ids, chunked deletes on large tables, '
  'and TRUNCATE for SDS-only staging tables.';

ANALYZE public.sales_import_batches;
