-- Browser-side Sales Daily Sheets import path.
--
-- Background
-- ----------
-- The Edge Function `sales-daily-sheets-import` was hitting the Edge
-- runtime CPU limit on larger CSVs because per-row JS parsing is the
-- bottleneck (the heavy SQL inside `apply_sales_daily_sheets_to_payroll`
-- is fine — it already runs with `statement_timeout = 0`).
--
-- The smallest safe fix is to do the CSV parsing in the user's browser
-- and call the existing staged-row RPCs directly via PostgREST. To make
-- that safe we:
--   1. Re-define `delete_sales_daily_sheets_staged_rows_for_batch` and
--      `insert_sales_daily_sheets_staged_rows_chunk` with the SAME
--      elevated-access guards used by `trigger_sales_daily_sheets_import`
--      and `apply_sales_daily_sheets_to_payroll`. Stylist/assistant
--      users (who never pass `private.user_has_elevated_access()`) cannot
--      reach the staging table.
--   2. Grant EXECUTE on those two RPCs to `authenticated` (plus
--      `service_role`, kept so the Edge Function still works while we
--      cut over).
--   3. Add a small `set_sales_daily_sheets_batch_status` RPC so the
--      browser can move the batch through processing → completed/failed
--      without exposing direct UPDATEs on the table to ordinary
--      authenticated users.
--
-- Behaviour: same staging table, same staged-row shape, same
-- `apply_sales_daily_sheets_to_payroll` finaliser, same
-- location-scoped replacement logic.

-- 1) Re-define delete RPC with elevated guard + batch-creator allow.
CREATE OR REPLACE FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(p_batch_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_created_by uuid;
BEGIN
  IF p_batch_id IS NULL THEN
    RAISE EXCEPTION 'p_batch_id is required';
  END IF;

  -- Service role calls (Edge fallback) bypass auth.uid() checks.
  IF v_uid IS NOT NULL THEN
    SELECT b.created_by INTO v_created_by
    FROM public.sales_daily_sheets_import_batches b
    WHERE b.id = p_batch_id;

    IF v_created_by IS NULL THEN
      RAISE EXCEPTION 'sales daily sheets batch not found: %', p_batch_id;
    END IF;

    IF NOT (
      (SELECT private.user_has_elevated_access())
      AND (
        (SELECT private.user_has_elevated_access())
        OR v_created_by = v_uid
      )
    ) THEN
      RAISE EXCEPTION 'not authorized';
    END IF;
  END IF;

  PERFORM set_config('statement_timeout', '0', true);

  DELETE FROM public.sales_daily_sheets_staged_rows
  WHERE batch_id = p_batch_id;
END;
$$;

ALTER FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(uuid) OWNER TO postgres;

COMMENT ON FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(uuid) IS
  'Clears staged rows for one Sales Daily Sheets batch. Elevated (manager/admin/superadmin) callers only; service_role bypasses for Edge.';

REVOKE ALL ON FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_sales_daily_sheets_staged_rows_for_batch(uuid) TO service_role;


-- 2) Re-define chunked-insert RPC with the same guards. Validates that
--    every row in the chunk references the same batch_id and that the
--    caller is allowed to write to that batch.
CREATE OR REPLACE FUNCTION public.insert_sales_daily_sheets_staged_rows_chunk(p_rows jsonb)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_batch_id uuid;
  v_created_by uuid;
  v_distinct_batches integer;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'insert_sales_daily_sheets_staged_rows_chunk: p_rows must be a JSON array';
  END IF;

  IF jsonb_array_length(p_rows) = 0 THEN
    RETURN;
  END IF;

  -- Authorize only when running as an end user; service_role passes through.
  IF v_uid IS NOT NULL THEN
    SELECT count(DISTINCT (elem->>'batch_id'))::integer
    INTO v_distinct_batches
    FROM jsonb_array_elements(p_rows) AS _(elem)
    WHERE elem ? 'batch_id'
      AND coalesce(elem->>'batch_id', '') <> '';

    IF v_distinct_batches IS NULL OR v_distinct_batches = 0 THEN
      RAISE EXCEPTION 'insert_sales_daily_sheets_staged_rows_chunk: rows must include batch_id';
    END IF;

    IF v_distinct_batches > 1 THEN
      RAISE EXCEPTION 'insert_sales_daily_sheets_staged_rows_chunk: a chunk must reference one batch_id';
    END IF;

    SELECT (elem->>'batch_id')::uuid
    INTO v_batch_id
    FROM jsonb_array_elements(p_rows) AS _(elem)
    LIMIT 1;

    SELECT b.created_by INTO v_created_by
    FROM public.sales_daily_sheets_import_batches b
    WHERE b.id = v_batch_id;

    IF v_created_by IS NULL THEN
      RAISE EXCEPTION 'sales daily sheets batch not found: %', v_batch_id;
    END IF;

    IF NOT (
      (SELECT private.user_has_elevated_access())
      AND (
        (SELECT private.user_has_elevated_access())
        OR v_created_by = v_uid
      )
    ) THEN
      RAISE EXCEPTION 'not authorized';
    END IF;
  END IF;

  PERFORM set_config('statement_timeout', '0', true);

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
  'Bulk inserts a chunk of staged rows for one Sales Daily Sheets batch. Elevated (manager/admin/superadmin) callers only; service_role bypasses for Edge.';

REVOKE ALL ON FUNCTION public.insert_sales_daily_sheets_staged_rows_chunk(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.insert_sales_daily_sheets_staged_rows_chunk(jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.insert_sales_daily_sheets_staged_rows_chunk(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.insert_sales_daily_sheets_staged_rows_chunk(jsonb) TO service_role;


-- 3) Tiny status-update RPC so we don't have to expose UPDATE on the
--    batches table to authenticated. Mirrors the columns the Edge
--    Function previously updated.
CREATE OR REPLACE FUNCTION public.set_sales_daily_sheets_batch_status(
  p_batch_id uuid,
  p_status text,
  p_message text DEFAULT NULL,
  p_error_message text DEFAULT NULL,
  p_rows_staged integer DEFAULT NULL,
  p_rows_loaded integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_created_by uuid;
  v_status text := lower(trim(coalesce(p_status, '')));
BEGIN
  IF p_batch_id IS NULL THEN
    RAISE EXCEPTION 'p_batch_id is required';
  END IF;

  IF v_status NOT IN ('queued', 'processing', 'completed', 'failed') THEN
    RAISE EXCEPTION 'invalid status: %', p_status;
  END IF;

  SELECT b.created_by INTO v_created_by
  FROM public.sales_daily_sheets_import_batches b
  WHERE b.id = p_batch_id;

  IF v_created_by IS NULL THEN
    RAISE EXCEPTION 'sales daily sheets batch not found: %', p_batch_id;
  END IF;

  IF v_uid IS NOT NULL THEN
    IF NOT (
      (SELECT private.user_has_elevated_access())
      AND (
        (SELECT private.user_has_elevated_access())
        OR v_created_by = v_uid
      )
    ) THEN
      RAISE EXCEPTION 'not authorized';
    END IF;
  END IF;

  UPDATE public.sales_daily_sheets_import_batches b
  SET
    status = v_status,
    message = COALESCE(p_message, b.message),
    error_message = CASE
      WHEN v_status = 'failed' THEN left(COALESCE(p_error_message, b.error_message, ''), 4000)
      WHEN v_status = 'completed' THEN NULL
      ELSE COALESCE(p_error_message, b.error_message)
    END,
    rows_staged = COALESCE(p_rows_staged, b.rows_staged),
    rows_loaded = COALESCE(p_rows_loaded, b.rows_loaded)
  WHERE b.id = p_batch_id;

  RETURN jsonb_build_object(
    'batch_id', p_batch_id,
    'status', v_status
  );
END;
$$;

ALTER FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer) OWNER TO postgres;

COMMENT ON FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer) IS
  'Updates status/message/error/rows_* on a Sales Daily Sheets batch. Elevated (manager/admin/superadmin) callers only; service_role bypasses for Edge.';

REVOKE ALL ON FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer) TO service_role;
