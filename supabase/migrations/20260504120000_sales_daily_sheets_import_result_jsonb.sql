-- Persist structured import metrics on the sheet batch row for Admin Imports UI.
-- Extends set_sales_daily_sheets_batch_status to merge JSON; apply_sales_daily_sheets_to_payroll
-- fills server-derived counts after load_raw_sales_rows_to_transactions.

ALTER TABLE public.sales_daily_sheets_import_batches
  ADD COLUMN IF NOT EXISTS import_result jsonb NOT NULL DEFAULT '{}'::jsonb;

COMMENT ON COLUMN public.sales_daily_sheets_import_batches.import_result IS
  'Structured metrics (location name, date range, row counts). Merged by set_sales_daily_sheets_batch_status and apply_sales_daily_sheets_to_payroll.';

DROP FUNCTION IF EXISTS public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer);

CREATE OR REPLACE FUNCTION public.set_sales_daily_sheets_batch_status(
  p_batch_id uuid,
  p_status text,
  p_message text DEFAULT NULL,
  p_error_message text DEFAULT NULL,
  p_rows_staged integer DEFAULT NULL,
  p_rows_loaded integer DEFAULT NULL,
  p_import_result jsonb DEFAULT NULL
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
    rows_loaded = COALESCE(p_rows_loaded, b.rows_loaded),
    import_result = CASE
      WHEN p_import_result IS NULL THEN b.import_result
      ELSE coalesce(b.import_result, '{}'::jsonb) || p_import_result
    END
  WHERE b.id = p_batch_id;

  RETURN jsonb_build_object(
    'batch_id', p_batch_id,
    'status', v_status
  );
END;
$$;

ALTER FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer, jsonb) OWNER TO postgres;

COMMENT ON FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer, jsonb) IS
  'Updates status/message/error/rows_* and merges import_result JSON on a Sales Daily Sheets batch.';

REVOKE ALL ON FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer, jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer, jsonb) FROM anon;
GRANT EXECUTE ON FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.set_sales_daily_sheets_batch_status(uuid, text, text, text, integer, integer, jsonb) TO service_role;
