-- Edge import uses PostgREST for DELETE/INSERT on sales_daily_sheets_staged_rows; each HTTP request
-- runs as a separate SQL statement with the pool default statement_timeout. Large imports can hit
-- "canceling statement due to statement timeout" before apply_sales_daily_sheets_to_payroll runs.
-- These RPCs run the same DML inside PL/pgSQL with transaction-local statement_timeout disabled.

CREATE OR REPLACE FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(p_batch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM set_config('statement_timeout', '0', true);

  DELETE FROM public.sales_daily_sheets_staged_rows
  WHERE batch_id = p_batch_id;
END;
$$;

ALTER FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(uuid) IS
  'Used by Edge sales-daily-sheets-import: clears staged rows for one batch with statement_timeout disabled.';

REVOKE ALL ON FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(uuid) TO service_role;


CREATE OR REPLACE FUNCTION public.insert_sales_daily_sheets_staged_rows_chunk(p_rows jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM set_config('statement_timeout', '0', true);

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'insert_sales_daily_sheets_staged_rows_chunk: p_rows must be a JSON array';
  END IF;

  INSERT INTO public.sales_daily_sheets_staged_rows (
    batch_id,
    line_number,
    invoice,
    sale_date,
    pay_week_start,
    pay_week_end,
    pay_date,
    customer_name,
    product_service_name,
    quantity,
    price_ex_gst,
    derived_staff_paid_display_name,
    actual_commission_amount,
    assistant_commission_amount,
    payroll_status,
    stylist_visible_note,
    location_id,
    extras
  )
  SELECT
    (elem->>'batch_id')::uuid,
    (elem->>'line_number')::integer,
    nullif(elem->>'invoice', ''),
    nullif(elem->>'sale_date', ''),
    CASE
      WHEN coalesce(nullif(trim(elem->>'pay_week_start'), ''), '') = '' THEN NULL
      ELSE (elem->>'pay_week_start')::date
    END,
    CASE
      WHEN coalesce(nullif(trim(elem->>'pay_week_end'), ''), '') = '' THEN NULL
      ELSE (elem->>'pay_week_end')::date
    END,
    CASE
      WHEN coalesce(nullif(trim(elem->>'pay_date'), ''), '') = '' THEN NULL
      ELSE (elem->>'pay_date')::date
    END,
    nullif(elem->>'customer_name', ''),
    nullif(elem->>'product_service_name', ''),
    nullif(elem->>'quantity', '')::numeric,
    nullif(elem->>'price_ex_gst', '')::numeric,
    nullif(elem->>'derived_staff_paid_display_name', ''),
    nullif(elem->>'actual_commission_amount', '')::numeric,
    nullif(elem->>'assistant_commission_amount', '')::numeric,
    nullif(elem->>'payroll_status', ''),
    nullif(elem->>'stylist_visible_note', ''),
    CASE
      WHEN elem ? 'location_id'
        AND coalesce(elem->>'location_id', '') <> ''
        AND (elem->>'location_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      THEN (elem->>'location_id')::uuid
      ELSE NULL
    END,
    coalesce(elem->'extras', '{}'::jsonb)
  FROM jsonb_array_elements(p_rows) AS _(elem);
END;
$$;

ALTER FUNCTION public.insert_sales_daily_sheets_staged_rows_chunk(jsonb) OWNER TO postgres;

COMMENT ON FUNCTION public.insert_sales_daily_sheets_staged_rows_chunk(jsonb) IS
  'Used by Edge sales-daily-sheets-import: bulk insert staged rows with statement_timeout disabled.';

REVOKE ALL ON FUNCTION public.insert_sales_daily_sheets_staged_rows_chunk(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.insert_sales_daily_sheets_staged_rows_chunk(jsonb) TO service_role;
