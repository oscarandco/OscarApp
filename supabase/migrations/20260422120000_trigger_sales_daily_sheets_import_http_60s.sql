-- pgsql-http defaults to a 5s request timeout (error: "Operation timed out after ~5002 milliseconds with 0 bytes received").
-- Client AbortSignal on the RPC does not affect libcurl inside Postgres; raise the HTTP extension timeout for Edge calls only.

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
  v_http_status int;
  v_http_content text;
  v_body jsonb;
  v_rows_staged int;
  v_rows_loaded int;
  v_batch_rows_loaded int;
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

  SELECT
    nullif(trim(c.sales_daily_import_edge_url), ''),
    nullif(trim(c.internal_import_secret), '')
  INTO v_edge_url, v_secret
  FROM private.sales_daily_sheets_import_config c
  WHERE c.id = 1;

  IF v_edge_url IS NOT NULL AND v_secret IS NOT NULL
     AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'http') THEN
    BEGIN
      PERFORM set_config('http.curlopt_timeout_ms', '60000', true);

      SELECT status, content::text
      INTO v_http_status, v_http_content
      FROM extensions.http_post(
        v_edge_url,
        jsonb_build_object(
          'batch_id', v_batch_id,
          'storage_path', v_path,
          'internal_secret', v_secret,
          'location_id', p_location_id
        )::text,
        'application/json'
      );

      IF v_http_status IS NULL OR v_http_status < 200 OR v_http_status >= 300 THEN
        UPDATE public.sales_daily_sheets_import_batches b
        SET
          status = 'failed',
          error_message = left(
            coalesce(v_http_content, 'HTTP ' || coalesce(v_http_status::text, 'no response')),
            4000
          ),
          message = 'Import failed (Edge Function HTTP error)'
        WHERE b.id = v_batch_id;

        RETURN jsonb_build_object(
          'success', false,
          'message', 'Import failed: Edge Function returned an error',
          'batch_id', v_batch_id,
          'storage_path', v_path,
          'rows_staged', NULL,
          'rows_loaded', NULL,
          'status', 'failed',
          'error_message', left(coalesce(v_http_content, 'HTTP error'), 2000)
        );
      END IF;

      v_body := v_http_content::jsonb;
      IF NOT (
        (v_body @> '{"ok": true}'::jsonb)
        OR (lower(trim(coalesce(v_body->>'ok', ''))) IN ('true', 't', '1'))
      ) THEN
        UPDATE public.sales_daily_sheets_import_batches b
        SET
          status = 'failed',
          error_message = left(coalesce(v_body->>'error', v_http_content), 4000),
          message = 'Import failed (Edge Function reported failure)'
        WHERE b.id = v_batch_id;

        RETURN jsonb_build_object(
          'success', false,
          'message', coalesce(v_body->>'error', 'Import failed'),
          'batch_id', v_batch_id,
          'storage_path', v_path,
          'rows_staged', NULL,
          'rows_loaded', NULL,
          'status', 'failed',
          'error_message', coalesce(v_body->>'error', v_http_content)
        );
      END IF;

      UPDATE public.sales_daily_sheets_staged_rows r
      SET location_id = p_location_id
      WHERE r.batch_id = v_batch_id;

      v_rows_staged := coalesce(
        (v_body->>'rows_inserted')::int,
        (SELECT count(*)::int FROM public.sales_daily_sheets_staged_rows r WHERE r.batch_id = v_batch_id)
      );

      PERFORM private.run_sales_daily_sheets_merge_if_installed(v_batch_id);

      SELECT b.rows_loaded
      INTO v_batch_rows_loaded
      FROM public.sales_daily_sheets_import_batches b
      WHERE b.id = v_batch_id;

      v_rows_loaded := coalesce(v_batch_rows_loaded, v_rows_staged);

      UPDATE public.sales_daily_sheets_import_batches b
      SET
        status = 'completed',
        rows_staged = v_rows_staged,
        rows_loaded = v_rows_loaded,
        message = 'Import completed',
        error_message = NULL
      WHERE b.id = v_batch_id;

      RETURN jsonb_build_object(
        'success', true,
        'message', 'Import completed',
        'batch_id', v_batch_id,
        'storage_path', v_path,
        'rows_staged', v_rows_staged,
        'rows_loaded', v_rows_loaded,
        'status', 'completed',
        'error_message', NULL
      );

    EXCEPTION
      WHEN OTHERS THEN
        UPDATE public.sales_daily_sheets_import_batches b
        SET
          status = 'failed',
          error_message = left(SQLERRM, 4000),
          message = 'Import failed (exception during HTTP or merge)'
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

  ELSIF to_regprocedure('public.sales_daily_sheets_import_pipeline_sql(uuid,text)') IS NOT NULL THEN
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
    UPDATE public.sales_daily_sheets_import_batches b
    SET
      status = 'failed',
      error_message =
        'Import pipeline not configured: populate private.sales_daily_sheets_import_config (id=1) with Edge URL and secret, '
        || 'enable the http extension, or define public.sales_daily_sheets_import_pipeline_sql(uuid,text).',
      message = 'Import not configured'
    WHERE b.id = v_batch_id;

    RETURN jsonb_build_object(
      'success', false,
      'message', 'Import pipeline not configured on the database',
      'batch_id', v_batch_id,
      'storage_path', v_path,
      'rows_staged', NULL,
      'rows_loaded', NULL,
      'status', 'failed',
      'error_message',
      'Configure private.sales_daily_sheets_import_config, enable http extension, or provide sales_daily_sheets_import_pipeline_sql.'
    );
  END IF;
END;
$$;

ALTER FUNCTION public.trigger_sales_daily_sheets_import(text, uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.trigger_sales_daily_sheets_import(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trigger_sales_daily_sheets_import(text, uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.trigger_sales_daily_sheets_import(text, uuid) FROM anon;
