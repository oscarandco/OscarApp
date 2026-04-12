-- Sales Daily Sheets import: store Edge URL + internal secret in private.* (hosted Supabase cannot set custom GUCs).
-- Replaces current_setting('app.sales_daily_import_edge_url' / 'app.internal_import_secret') in trigger_sales_daily_sheets_import.
-- Does not modify payroll or commission objects.

CREATE TABLE IF NOT EXISTS private.sales_daily_sheets_import_config (
  id integer PRIMARY KEY CHECK (id = 1),
  sales_daily_import_edge_url text,
  internal_import_secret text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE private.sales_daily_sheets_import_config IS
  'Singleton (id=1) runtime config for trigger_sales_daily_sheets_import. Secrets are stored for server-side use only; restrict access.';

-- Not for PostgREST / browser: no SELECT for anon/authenticated.
REVOKE ALL ON TABLE private.sales_daily_sheets_import_config FROM PUBLIC;
REVOKE ALL ON TABLE private.sales_daily_sheets_import_config FROM anon;
REVOKE ALL ON TABLE private.sales_daily_sheets_import_config FROM authenticated;

INSERT INTO private.sales_daily_sheets_import_config (id, sales_daily_import_edge_url, internal_import_secret)
VALUES (
  1,
  'https://qrqmramuvdqlvrtpvajo.supabase.co/functions/v1/sales-daily-sheets-import',
  '7f3c9a1e5b8d4c2f9a7e1b6c3d8f4a2e9c1b7d5f3a8e6c2b'
)
ON CONFLICT (id) DO UPDATE SET
  sales_daily_import_edge_url = EXCLUDED.sales_daily_import_edge_url,
  internal_import_secret = EXCLUDED.internal_import_secret,
  updated_at = now();

CREATE OR REPLACE FUNCTION public.trigger_sales_daily_sheets_import(p_storage_path text)
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
    created_by
  )
  VALUES (
    v_batch_id,
    v_path,
    'processing',
    NULL,
    NULL,
    NULL,
    NULL,
    v_uid
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
      SELECT status, content::text
      INTO v_http_status, v_http_content
      FROM extensions.http_post(
        v_edge_url,
        jsonb_build_object(
          'batch_id', v_batch_id,
          'storage_path', v_path,
          'internal_secret', v_secret
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

REVOKE ALL ON FUNCTION public.trigger_sales_daily_sheets_import(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trigger_sales_daily_sheets_import(text) TO authenticated;
REVOKE ALL ON FUNCTION public.trigger_sales_daily_sheets_import(text) FROM anon;
