-- Admin Imports: selected location on sheet batches, trigger + Edge pass-through, apply prefers it,
-- list locations RPC, full SDS import reset RPC. Weekly payroll RPCs unchanged.

ALTER TABLE public.sales_daily_sheets_import_batches
  ADD COLUMN IF NOT EXISTS selected_location_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint c
    JOIN pg_class rel ON rel.oid = c.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    WHERE nsp.nspname = 'public'
      AND rel.relname = 'sales_daily_sheets_import_batches'
      AND c.conname = 'sales_daily_sheets_import_batches_selected_location_id_fkey'
  ) THEN
    ALTER TABLE public.sales_daily_sheets_import_batches
      ADD CONSTRAINT sales_daily_sheets_import_batches_selected_location_id_fkey
      FOREIGN KEY (selected_location_id)
      REFERENCES public.locations (id)
      ON DELETE SET NULL;
  END IF;
END
$$;

COMMENT ON COLUMN public.sales_daily_sheets_import_batches.selected_location_id IS
  'Location chosen in Admin Imports; applied to staged rows and payroll merge.';

DROP FUNCTION IF EXISTS public.trigger_sales_daily_sheets_import(text);

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

CREATE OR REPLACE FUNCTION public.list_active_locations_for_import()
RETURNS TABLE (id uuid, code text, name text)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN QUERY
  SELECT l.id, l.code, l.name
  FROM public.locations l
  WHERE l.is_active = true
  ORDER BY l.name;
END;
$$;

ALTER FUNCTION public.list_active_locations_for_import() OWNER TO postgres;

COMMENT ON FUNCTION public.list_active_locations_for_import() IS
  'Active locations for Admin Imports dropdown (elevated users only).';

REVOKE ALL ON FUNCTION public.list_active_locations_for_import() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_active_locations_for_import() TO authenticated;
REVOKE ALL ON FUNCTION public.list_active_locations_for_import() FROM anon;

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

  DELETE FROM public.sales_transactions st
  WHERE st.import_batch_id IN (
    SELECT b.id
    FROM public.sales_import_batches b
    WHERE b.source_name = 'SalesDailySheets'
  );
  GET DIAGNOSTICS n_tx = ROW_COUNT;

  DELETE FROM public.raw_sales_import_rows rr
  WHERE rr.import_batch_id IN (
    SELECT b.id
    FROM public.sales_import_batches b
    WHERE b.source_name = 'SalesDailySheets'
  );
  GET DIAGNOSTICS n_raw = ROW_COUNT;

  DELETE FROM public.sales_import_batches
  WHERE source_name = 'SalesDailySheets';
  GET DIAGNOSTICS n_batch = ROW_COUNT;

  DELETE FROM public.sales_daily_sheets_staged_rows;
  GET DIAGNOSTICS n_staged = ROW_COUNT;

  DELETE FROM public.sales_daily_sheets_import_batches;
  GET DIAGNOSTICS n_sheet = ROW_COUNT;

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
  'Destructive reset: removes all Sales Daily Sheets import data (elevated users only). Idempotent.';

REVOKE ALL ON FUNCTION public.delete_all_sales_daily_sheets_import_data() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_all_sales_daily_sheets_import_data() TO authenticated;
REVOKE ALL ON FUNCTION public.delete_all_sales_daily_sheets_import_data() FROM anon;

CREATE OR REPLACE FUNCTION public.apply_sales_daily_sheets_to_payroll(p_batch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $$
DECLARE
  v_sheet public.sales_daily_sheets_import_batches%ROWTYPE;
  v_payroll_id uuid;
  v_staged integer;
  v_loaded integer;
  v_source_file text;
  v_location_id uuid;
BEGIN
  SELECT *
  INTO v_sheet
  FROM public.sales_daily_sheets_import_batches b
  WHERE b.id = p_batch_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales daily sheets batch not found: %', p_batch_id;
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      (SELECT private.user_has_elevated_access())
      OR v_sheet.created_by = auth.uid()
    ) THEN
      RAISE EXCEPTION 'not authorized';
    END IF;
  END IF;

  SELECT count(*)::integer
  INTO v_staged
  FROM public.sales_daily_sheets_staged_rows r
  WHERE r.batch_id = p_batch_id;

  IF v_staged = 0 THEN
    RAISE EXCEPTION 'no staged rows for batch %', p_batch_id;
  END IF;

  v_payroll_id := v_sheet.payroll_import_batch_id;

  IF v_payroll_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.sales_import_batches b WHERE b.id = v_payroll_id
  ) THEN
    v_payroll_id := NULL;
    UPDATE public.sales_daily_sheets_import_batches b
    SET payroll_import_batch_id = NULL
    WHERE b.id = p_batch_id;
  END IF;

  v_source_file := trim(regexp_replace(trim(coalesce(v_sheet.storage_path, '')), '^.*/', ''));
  v_source_file := nullif(v_source_file, '');
  IF v_source_file IS NULL THEN
    v_source_file := trim(coalesce(v_sheet.storage_path, ''));
  END IF;

  v_location_id := v_sheet.selected_location_id;

  IF v_location_id IS NULL THEN
    v_location_id := (
      SELECT r.location_id
      FROM public.sales_daily_sheets_staged_rows r
      WHERE r.batch_id = p_batch_id
        AND r.location_id IS NOT NULL
      LIMIT 1
    );
  END IF;

  IF v_location_id IS NULL THEN
    v_location_id := public.get_location_id_from_filename(v_source_file);
  END IF;

  IF v_payroll_id IS NULL THEN
    IF v_location_id IS NULL THEN
      RAISE EXCEPTION
        'cannot resolve location_id for sales daily sheets batch % (set selected_location_id, staged location_id, or use a storage filename that maps via get_location_id_from_filename)',
        p_batch_id;
    END IF;

    INSERT INTO public.sales_import_batches (
      source_name,
      source_file_name,
      location_id,
      imported_by_user_id,
      status,
      notes
    )
    VALUES (
      'SalesDailySheets',
      v_source_file,
      v_location_id,
      v_sheet.created_by,
      'pending',
      format('Sales Daily Sheets staged import; sheet batch %s', p_batch_id)
    )
    RETURNING id INTO v_payroll_id;

    UPDATE public.sales_daily_sheets_import_batches b
    SET payroll_import_batch_id = v_payroll_id
    WHERE b.id = p_batch_id;
  END IF;

  DELETE FROM public.sales_transactions st
  WHERE st.import_batch_id = v_payroll_id;

  DELETE FROM public.raw_sales_import_rows rr
  WHERE rr.import_batch_id = v_payroll_id;

  INSERT INTO public.raw_sales_import_rows (
    import_batch_id,
    category,
    first_name,
    qty,
    prod_total,
    prod_id,
    sale_datetime,
    source_document_number,
    description,
    whole_name,
    product_type,
    parent_prod_type,
    prod_cat,
    staff_work_name,
    raw_location,
    row_num,
    raw_payload
  )
  SELECT
    v_payroll_id,

    CASE
      WHEN nullif(btrim(coalesce(r.extras->>'category', r.extras->>'CATEGORY')), '') IS NULL THEN NULL
      WHEN regexp_replace(btrim(coalesce(r.extras->>'category', r.extras->>'CATEGORY')), '\.0+$', '') ~ '^-?[0-9]+$'
        THEN regexp_replace(btrim(coalesce(r.extras->>'category', r.extras->>'CATEGORY')), '\.0+$', '')::integer
      ELSE NULL
    END,

    CASE
      WHEN nullif(btrim(r.derived_staff_paid_display_name), '') IS NOT NULL THEN
        split_part(btrim(r.derived_staff_paid_display_name), ' ', 1)
      WHEN nullif(btrim(r.extras->>'FIRST_NAME'), '') IS NOT NULL THEN
        btrim(r.extras->>'FIRST_NAME')
      WHEN nullif(btrim(r.extras->>'NAME'), '') IS NOT NULL THEN
        split_part(btrim(r.extras->>'NAME'), ' ', 1)
      ELSE NULL
    END,

    CASE
      WHEN r.quantity IS NOT NULL
        AND r.quantity::text ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        round(r.quantity)::integer
      WHEN nullif(
        replace(btrim(coalesce(r.extras->>'QTY', r.extras->>'qty')), ',', ''),
        ''
      ) IS NOT NULL
        AND regexp_replace(
          btrim(coalesce(r.extras->>'QTY', r.extras->>'qty')),
          '\.0+$',
          ''
        ) ~ '^-?[0-9]+$' THEN
        regexp_replace(
          btrim(coalesce(r.extras->>'QTY', r.extras->>'qty')),
          '\.0+$',
          ''
        )::integer
      ELSE NULL
    END,

    CASE
      WHEN r.price_ex_gst IS NOT NULL THEN
        round(r.price_ex_gst::numeric, 2)
      WHEN nullif(
        replace(
          btrim(coalesce(r.extras->>'PROD_TOTAL', r.extras->>'prod_total')),
          ',',
          ''
        ),
        ''
      ) IS NOT NULL
        AND replace(
          btrim(coalesce(r.extras->>'PROD_TOTAL', r.extras->>'prod_total')),
          ',',
          ''
        ) ~ '^-?\d+(\.\d+)?$' THEN
        replace(
          btrim(coalesce(r.extras->>'PROD_TOTAL', r.extras->>'prod_total')),
          ',',
          ''
        )::numeric(12, 2)
      ELSE NULL
    END,

    nullif(
      btrim(coalesce(r.extras->>'prod_id', r.extras->>'PROD_ID')),
      ''
    ),

    COALESCE(
      CASE
        WHEN nullif(btrim(coalesce(r.sale_date, r.extras->>'DATE')), '') IS NULL THEN NULL
        WHEN btrim(coalesce(r.sale_date, r.extras->>'DATE')) ~ '^\d{4}-\d{2}-\d{2}' THEN
          (
            left(btrim(coalesce(r.sale_date, r.extras->>'DATE')), 10)::date + time '12:00'
          ) AT TIME ZONE 'Pacific/Auckland'
        ELSE
          btrim(coalesce(r.sale_date, r.extras->>'DATE'))::timestamptz
      END,
      (
        coalesce(r.pay_week_start, r.pay_date, CURRENT_DATE)::timestamp + interval '12 hours'
      ) AT TIME ZONE 'Pacific/Auckland'
    ),

    nullif(
      btrim(
        coalesce(
          r.invoice,
          r.extras->>'SOURCE_DOCUMENT_NUMBER',
          r.extras->>'source_document_number'
        )
      ),
      ''
    ),

    coalesce(
      nullif(btrim(r.product_service_name), ''),
      nullif(btrim(r.extras->>'DESCRIPTION'), ''),
      '(daily sheet row)'
    ),

    nullif(
      btrim(
        coalesce(
          r.customer_name,
          r.extras->>'WHOLE_NAME',
          r.extras->>'whole_name'
        )
      ),
      ''
    ),

    coalesce(
      nullif(btrim(r.extras->>'product_type'), ''),
      nullif(btrim(r.extras->>'PRODUCT_TYPE'), ''),
      'Service'
    ),

    nullif(
      btrim(
        coalesce(
          r.extras->>'parent_prod_type',
          r.extras->>'PARENT_PROD_TYPE'
        )
      ),
      ''
    ),

    nullif(
      btrim(coalesce(r.extras->>'prod_cat', r.extras->>'PROD_CAT')),
      ''
    ),

    nullif(
      btrim(
        coalesce(
          r.derived_staff_paid_display_name,
          r.extras->>'NAME'
        )
      ),
      ''
    ),

    v_payroll_id::text,
    r.line_number,

    r.extras
      || jsonb_build_object(
        'sales_daily_sheets_staged_row_id', r.id,
        'sheet_batch_id', p_batch_id,
        'storage_path', v_sheet.storage_path,
        'sale_date_raw', r.sale_date,
        'pay_week_start', r.pay_week_start,
        'pay_week_end', r.pay_week_end,
        'pay_date', r.pay_date,
        'payroll_status', r.payroll_status,
        'stylist_visible_note', r.stylist_visible_note,
        'actual_commission_amount', r.actual_commission_amount,
        'assistant_commission_amount', r.assistant_commission_amount,
        'derived_staff_paid_display_name', r.derived_staff_paid_display_name,
        'staged_invoice', r.invoice,
        'staged_product_service_name', r.product_service_name,
        'staged_customer_name', r.customer_name,
        'staged_quantity', r.quantity,
        'staged_price_ex_gst', r.price_ex_gst,
        'selected_location_id', v_sheet.selected_location_id
      )
  FROM public.sales_daily_sheets_staged_rows r
  WHERE r.batch_id = p_batch_id
  ORDER BY r.line_number;

  v_loaded := public.load_raw_sales_rows_to_transactions(v_payroll_id);

  UPDATE public.sales_import_batches b
  SET
    status = 'processed',
    row_count = v_loaded,
    imported_by_user_id = coalesce(b.imported_by_user_id, auth.uid()),
    updated_at = now()
  WHERE b.id = v_payroll_id;

  UPDATE public.sales_daily_sheets_import_batches b
  SET rows_loaded = v_loaded
  WHERE b.id = p_batch_id;
END;
$$;

ALTER FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) IS
  'Maps sales_daily_sheets_staged_rows into raw_sales_import_rows and runs load_raw_sales_rows_to_transactions; idempotent per sheet batch.';

REVOKE ALL ON FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) FROM anon;
