-- Merge server-side import metrics into sales_daily_sheets_import_batches.import_result
-- after apply (counts from sales_transactions before scoped delete + loader row count).
-- Depends on 20260504120000_sales_daily_sheets_import_result_jsonb.sql for the column.

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
  v_min_sale_date date;
  v_max_sale_date date;
  v_existing_before bigint := 0;
  v_existing_in_range bigint := 0;
  v_location_name text;
  t_mark timestamptz;
  t_apply_start timestamptz;
BEGIN
  PERFORM set_config('statement_timeout', '0', true);
  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=statement_timeout_disabled_tx_local',
    p_batch_id;

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

  t_apply_start := clock_timestamp();

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

  IF v_location_id IS NULL AND v_payroll_id IS NOT NULL THEN
    SELECT b.location_id INTO v_location_id
    FROM public.sales_import_batches b
    WHERE b.id = v_payroll_id;
  END IF;

  -- Same calendar-date extraction as the raw_sales_import_rows INSERT (Pacific/Auckland).
  SELECT
    min(x.staged_local_sale_date),
    max(x.staged_local_sale_date)
  INTO v_min_sale_date, v_max_sale_date
  FROM (
    SELECT
      ((COALESCE(
        CASE
          WHEN nullif(btrim(coalesce(r.sale_date, r.extras->>'DATE')), '') IS NULL THEN NULL::timestamptz
          WHEN btrim(coalesce(r.sale_date, r.extras->>'DATE')) ~ '^\d{4}-\d{2}-\d{2}' THEN
            ((left(btrim(coalesce(r.sale_date, r.extras->>'DATE')), 10)::date + time '12:00')
              AT TIME ZONE 'Pacific/Auckland')
          ELSE
            btrim(coalesce(r.sale_date, r.extras->>'DATE'))::timestamptz
        END,
        (coalesce(r.pay_week_start, r.pay_date, CURRENT_DATE)::timestamp + interval '12 hours')
          AT TIME ZONE 'Pacific/Auckland'
      )) AT TIME ZONE 'Pacific/Auckland')::date AS staged_local_sale_date
    FROM public.sales_daily_sheets_staged_rows r
    WHERE r.batch_id = p_batch_id
  ) x
  WHERE x.staged_local_sale_date IS NOT NULL;

  IF v_min_sale_date IS NULL OR v_max_sale_date IS NULL THEN
    RAISE EXCEPTION
      'cannot derive sale_date range from staged rows for batch % (need parseable sale_date / DATE / pay_week)',
      p_batch_id;
  END IF;

  IF v_location_id IS NOT NULL THEN
    SELECT count(*)::bigint
    INTO v_existing_before
    FROM public.sales_transactions st
    INNER JOIN public.sales_import_batches b ON b.id = st.import_batch_id
    WHERE b.source_name = 'SalesDailySheets'
      AND b.location_id = v_location_id
      AND st.location_id = v_location_id;

    SELECT count(*)::bigint
    INTO v_existing_in_range
    FROM public.sales_transactions st
    INNER JOIN public.sales_import_batches b ON b.id = st.import_batch_id
    WHERE b.source_name = 'SalesDailySheets'
      AND b.location_id = v_location_id
      AND st.location_id = v_location_id
      AND st.sale_date >= v_min_sale_date
      AND st.sale_date <= v_max_sale_date;
  END IF;

  SELECT l.name
  INTO v_location_name
  FROM public.locations l
  WHERE l.id = v_location_id
  LIMIT 1;

  t_mark := clock_timestamp();
  IF v_location_id IS NOT NULL THEN
    DELETE FROM public.sales_transactions st
    USING public.sales_import_batches b
    WHERE st.import_batch_id = b.id
      AND b.source_name = 'SalesDailySheets'
      AND b.location_id = v_location_id
      AND st.location_id = v_location_id
      AND st.sale_date >= v_min_sale_date
      AND st.sale_date <= v_max_sale_date;

    DELETE FROM public.raw_sales_import_rows rr
    USING public.sales_import_batches b
    WHERE rr.import_batch_id = b.id
      AND b.source_name = 'SalesDailySheets'
      AND b.location_id = v_location_id
      AND rr.sale_datetime IS NOT NULL
      AND ((rr.sale_datetime AT TIME ZONE 'Pacific/Auckland')::date) >= v_min_sale_date
      AND ((rr.sale_datetime AT TIME ZONE 'Pacific/Auckland')::date) <= v_max_sale_date;

    DELETE FROM public.sales_import_batches b
    WHERE b.source_name = 'SalesDailySheets'
      AND b.location_id = v_location_id
      AND (v_payroll_id IS NULL OR b.id <> v_payroll_id)
      AND NOT EXISTS (SELECT 1 FROM public.raw_sales_import_rows r WHERE r.import_batch_id = b.id)
      AND NOT EXISTS (SELECT 1 FROM public.sales_transactions st2 WHERE st2.import_batch_id = b.id);
  END IF;

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=location_scoped_deletes ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_mark)) * 1000)::bigint);

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

  t_mark := clock_timestamp();
  IF v_payroll_id IS NOT NULL THEN
    DELETE FROM public.sales_transactions st
    WHERE st.import_batch_id = v_payroll_id
      AND st.sale_date >= v_min_sale_date
      AND st.sale_date <= v_max_sale_date;

    DELETE FROM public.raw_sales_import_rows rr
    WHERE rr.import_batch_id = v_payroll_id
      AND rr.sale_datetime IS NOT NULL
      AND ((rr.sale_datetime AT TIME ZONE 'Pacific/Auckland')::date) >= v_min_sale_date
      AND ((rr.sale_datetime AT TIME ZONE 'Pacific/Auckland')::date) <= v_max_sale_date;
  END IF;

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=payroll_batch_preclear ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_mark)) * 1000)::bigint);

  t_mark := clock_timestamp();
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

    nullif(
      btrim(coalesce(r.extras->>'FIRST_NAME', r.extras->>'first_name')),
      ''
    ),

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
      btrim(coalesce(r.extras->>'WHOLE_NAME', r.extras->>'whole_name')),
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
      btrim(coalesce(r.extras->>'NAME', r.extras->>'name')),
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

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=raw_sales_import_rows_insert ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_mark)) * 1000)::bigint);

  t_mark := clock_timestamp();
  v_loaded := public.load_raw_sales_rows_to_transactions(v_payroll_id);

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=load_raw_sales_rows_to_transactions ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_mark)) * 1000)::bigint);

  t_mark := clock_timestamp();
  UPDATE public.sales_import_batches b
  SET
    status = 'processed',
    row_count = v_loaded,
    imported_by_user_id = coalesce(b.imported_by_user_id, auth.uid()),
    updated_at = now()
  WHERE b.id = v_payroll_id;

  UPDATE public.sales_daily_sheets_import_batches b
  SET
    rows_loaded = v_loaded,
    import_result = coalesce(b.import_result, '{}'::jsonb) || jsonb_build_object(
      'date_range_start', to_char(v_min_sale_date, 'YYYY-MM-DD'),
      'date_range_end', to_char(v_max_sale_date, 'YYYY-MM-DD'),
      'selected_location_name', coalesce(nullif(btrim(v_location_name), ''), ''),
      'existing_rows_before_import', v_existing_before,
      'existing_rows_replaced', v_existing_in_range,
      'existing_rows_unchanged', greatest(v_existing_before - v_existing_in_range, 0::bigint),
      'rows_loaded', v_loaded,
      'sales_transactions_created', v_loaded
    )
  WHERE b.id = p_batch_id;

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=final_batch_updates ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_mark)) * 1000)::bigint);

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=apply_sales_daily_sheets_to_payroll_total ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_apply_start)) * 1000)::bigint);
END;
$$;

ALTER FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) IS
  'Maps staged rows to raw_sales_import_rows and load_raw_sales_rows_to_transactions. '
  'Date-scoped deletes for the salon; merges import_result JSON (counts, date range, location name).';

REVOKE ALL ON FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) TO service_role;
REVOKE ALL ON FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid) FROM anon;

ALTER FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid)
  SET statement_timeout TO '0';
