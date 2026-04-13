-- Async Sales Daily Sheets import: RPC only validates, inserts a batch row (queued), and returns.
-- Long work runs in Edge (browser invokes the function with JWT); DB no longer calls extensions.http_post.

CREATE OR REPLACE FUNCTION public.trigger_sales_daily_sheets_import(
  p_storage_path text,
  p_location_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage, auth, extensions, private, pg_temp
AS $$
DECLARE
  v_path text := trim(p_storage_path);
  v_uid uuid := auth.uid();
  v_batch_id uuid := gen_random_uuid();
  v_bucket_id text;
  v_found boolean;
  v_edge_url text;
  v_secret text;
  v_sql jsonb;
  v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF v_path IS NULL OR v_path = '' THEN
    RAISE EXCEPTION 'p_storage_path is required';
  END IF;

  IF p_location_id IS NULL THEN
    RAISE EXCEPTION 'p_location_id is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.locations l
    WHERE l.id = p_location_id
      AND l.is_active
  ) THEN
    RAISE EXCEPTION 'invalid or inactive p_location_id';
  END IF;

  IF v_path ~ '\.\.' OR substring(v_path from 1 for 1) = '/' THEN
    RAISE EXCEPTION 'invalid storage path';
  END IF;

  IF v_path NOT LIKE 'incoming/%' THEN
    RAISE EXCEPTION 'storage path must start with incoming/';
  END IF;

  SELECT b.id INTO v_bucket_id
  FROM storage.buckets b
  WHERE b.name = 'sales-daily-sheets'
  LIMIT 1;

  IF v_bucket_id IS NULL THEN
    RAISE EXCEPTION 'storage bucket sales-daily-sheets is not configured';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM storage.objects o
    WHERE o.bucket_id = v_bucket_id
      AND o.name = v_path
  ) INTO v_found;

  IF NOT v_found THEN
    RAISE EXCEPTION 'object not found: % (upload to bucket sales-daily-sheets first)', v_path;
  END IF;

  SELECT
    nullif(trim(c.sales_daily_import_edge_url), ''),
    nullif(trim(c.internal_import_secret), '')
  INTO v_edge_url, v_secret
  FROM private.sales_daily_sheets_import_config c
  WHERE c.id = 1;

  IF v_edge_url IS NOT NULL AND v_secret IS NOT NULL THEN
    INSERT INTO public.sales_daily_sheets_import_batches (
      id,
      storage_path,
      status,
      message,
      rows_staged,
      rows_loaded,
      error_message,
      created_by,
      selected_location_id
    )
    VALUES (
      v_batch_id,
      v_path,
      'queued',
      'Queued — processing runs in Edge (client)',
      NULL,
      NULL,
      NULL,
      v_uid,
      p_location_id
    );

    RETURN jsonb_build_object(
      'success', true,
      'status', 'queued',
      'batch_id', v_batch_id,
      'storage_path', v_path,
      'message', 'Batch queued. Call the sales-daily-sheets-import Edge Function to process.',
      'rows_staged', NULL,
      'rows_loaded', NULL,
      'error_message', NULL
    );

  ELSIF to_regprocedure('public.sales_daily_sheets_import_pipeline_sql(uuid,text)') IS NOT NULL THEN
    INSERT INTO public.sales_daily_sheets_import_batches (
      id,
      storage_path,
      status,
      message,
      rows_staged,
      rows_loaded,
      error_message,
      created_by,
      selected_location_id
    )
    VALUES (
      v_batch_id,
      v_path,
      'processing',
      NULL,
      NULL,
      NULL,
      NULL,
      v_uid,
      p_location_id
    );

    BEGIN
      v_sql := public.sales_daily_sheets_import_pipeline_sql(v_batch_id, v_path);
      UPDATE public.sales_daily_sheets_staged_rows r
      SET location_id = p_location_id
      WHERE r.batch_id = v_batch_id;
      v_out := coalesce(v_sql, '{}'::jsonb);
      IF NOT (v_out ? 'error_message') THEN
        v_out := v_out || jsonb_build_object('error_message', NULL);
      END IF;
      RETURN v_out;
    EXCEPTION
      WHEN OTHERS THEN
        UPDATE public.sales_daily_sheets_import_batches b
        SET
          status = 'failed',
          error_message = left(SQLERRM, 4000),
          message = 'Import failed (sales_daily_sheets_import_pipeline_sql)'
        WHERE b.id = v_batch_id;

        RETURN jsonb_build_object(
          'success', false,
          'message', SQLERRM,
          'batch_id', v_batch_id,
          'storage_path', v_path,
          'rows_staged', NULL,
          'rows_loaded', NULL,
          'status', 'failed',
          'error_message', SQLERRM
        );
    END;

  ELSE
    INSERT INTO public.sales_daily_sheets_import_batches (
      id,
      storage_path,
      status,
      message,
      rows_staged,
      rows_loaded,
      error_message,
      created_by,
      selected_location_id
    )
    VALUES (
      v_batch_id,
      v_path,
      'failed',
      'Import not configured',
      NULL,
      NULL,
      'Populate private.sales_daily_sheets_import_config (id=1) with Edge URL and secret, or define public.sales_daily_sheets_import_pipeline_sql(uuid,text).',
      v_uid,
      p_location_id
    );

    RETURN jsonb_build_object(
      'success', false,
      'message', 'Import pipeline not configured on the database',
      'batch_id', v_batch_id,
      'storage_path', v_path,
      'rows_staged', NULL,
      'rows_loaded', NULL,
      'status', 'failed',
      'error_message',
      'Configure private.sales_daily_sheets_import_config, or provide sales_daily_sheets_import_pipeline_sql.'
    );
  END IF;
END;
$$;

ALTER FUNCTION public.trigger_sales_daily_sheets_import(text, uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.trigger_sales_daily_sheets_import(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trigger_sales_daily_sheets_import(text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.trigger_sales_daily_sheets_import(text, uuid) FROM anon;

GRANT EXECUTE ON FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) TO service_role;
