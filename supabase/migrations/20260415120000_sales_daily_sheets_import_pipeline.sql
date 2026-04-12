-- Upgrade Sales Daily Sheets import from stub RPC to full pipeline (Edge + optional SQL hook + optional merge).
-- Does not modify payroll/commission views or RPCs.
--
-- Prerequisites (live baseline): private.user_has_elevated_access(), storage bucket sales-daily-sheets,
-- public.sales_daily_sheets_import_batches, stub trigger_sales_daily_sheets_import.
--
-- Optional later: public.apply_sales_daily_sheets_to_payroll(uuid), public.sales_daily_sheets_import_pipeline_sql(uuid,text).
-- Configure: app.sales_daily_import_edge_url, app.internal_import_secret (see DEPLOY.md).

DO $$
BEGIN
  CREATE EXTENSION IF NOT EXISTS http WITH SCHEMA extensions;
EXCEPTION
  WHEN undefined_file OR insufficient_privilege OR duplicate_object THEN
    RAISE NOTICE 'http extension: enable in Dashboard if needed';
END
$$;

ALTER TABLE public.sales_daily_sheets_import_batches
  ADD COLUMN IF NOT EXISTS error_message text;

COMMENT ON COLUMN public.sales_daily_sheets_import_batches.error_message IS
  'Failure detail; also returned as error_message in trigger_sales_daily_sheets_import JSON.';

-- Staging table for CSV rows (filled by Edge Function sales-daily-sheets-import).
CREATE TABLE IF NOT EXISTS public.sales_daily_sheets_staged_rows (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  batch_id uuid NOT NULL REFERENCES public.sales_daily_sheets_import_batches (id) ON DELETE CASCADE,
  line_number integer NOT NULL,
  invoice text,
  sale_date text,
  pay_week_start date,
  pay_week_end date,
  pay_date date,
  customer_name text,
  product_service_name text,
  quantity numeric,
  price_ex_gst numeric,
  derived_staff_paid_display_name text,
  actual_commission_amount numeric,
  assistant_commission_amount numeric,
  payroll_status text,
  stylist_visible_note text,
  location_id uuid,
  extras jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT sales_daily_sheets_staged_rows_batch_line UNIQUE (batch_id, line_number)
);

CREATE INDEX IF NOT EXISTS sales_daily_sheets_staged_rows_batch_id_idx
  ON public.sales_daily_sheets_staged_rows (batch_id);

ALTER TABLE public.sales_daily_sheets_staged_rows ENABLE ROW LEVEL SECURITY;

COMMENT ON TABLE public.sales_daily_sheets_staged_rows IS
  'Parsed CSV lines per import batch; populated by Edge Function or sales_daily_sheets_import_pipeline_sql.';

-- Not exposed via PostgREST by default; writes go through Edge (service_role) or SECURITY DEFINER SQL hook.
GRANT USAGE ON SCHEMA private TO authenticated;

CREATE OR REPLACE FUNCTION private.run_sales_daily_sheets_merge_if_installed(p_batch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF to_regprocedure('public.apply_sales_daily_sheets_to_payroll(uuid)') IS NOT NULL THEN
    PERFORM public.apply_sales_daily_sheets_to_payroll(p_batch_id);
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION private.run_sales_daily_sheets_merge_if_installed(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.run_sales_daily_sheets_merge_if_installed(uuid) TO authenticated;

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

  v_edge_url := nullif(trim(current_setting('app.sales_daily_import_edge_url', true)), '');
  v_secret := nullif(trim(current_setting('app.internal_import_secret', true)), '');

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
        'Import pipeline not configured: set app.sales_daily_import_edge_url and app.internal_import_secret (and enable http extension), '
        || 'or define public.sales_daily_sheets_import_pipeline_sql(uuid,text).',
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
      'Configure Edge URL/secret or provide public.sales_daily_sheets_import_pipeline_sql(uuid,text).'
    );
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.trigger_sales_daily_sheets_import(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trigger_sales_daily_sheets_import(text) TO authenticated;
REVOKE ALL ON FUNCTION public.trigger_sales_daily_sheets_import(text) FROM anon;
