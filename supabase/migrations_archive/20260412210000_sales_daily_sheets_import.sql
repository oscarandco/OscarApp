-- Sales Daily Sheets: Storage bucket, import batch log, and RPC used by the SPA admin imports page.
-- Depends on: private.user_has_elevated_access() from 20260412120000_admin_access_management.sql
--
-- This migration does NOT parse CSV inside Postgres (no second bespoke ETL). It:
-- 1) ensures bucket `sales-daily-sheets` exists
-- 2) registers each trigger in public.sales_daily_sheets_import_batches
-- 3) verifies the object exists under storage.objects
-- Replace the INSERT/body with a call to your existing worker (Edge Function via pg_net, SQL function, etc.) when ready.

-- ---------------------------------------------------------------------------
-- Storage bucket (private; browser uses signed/anon upload via policies only)
-- ---------------------------------------------------------------------------
-- Bucket PK is text (id); keep id and name aligned with the Storage API.
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'sales-daily-sheets',
  'sales-daily-sheets',
  false,
  52428800,
  ARRAY['text/csv', 'text/plain', 'application/csv', 'application/vnd.ms-excel']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types;

-- ---------------------------------------------------------------------------
-- Import batch log (extend with your pipeline metrics)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sales_daily_sheets_import_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  storage_path text NOT NULL,
  status text NOT NULL DEFAULT 'registered',
  message text,
  rows_staged integer,
  rows_loaded integer,
  created_by uuid REFERENCES auth.users (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS sales_daily_sheets_import_batches_created_at_idx
  ON public.sales_daily_sheets_import_batches (created_at DESC);

ALTER TABLE public.sales_daily_sheets_import_batches ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS sales_daily_sheets_batches_select_own ON public.sales_daily_sheets_import_batches;
CREATE POLICY sales_daily_sheets_batches_select_own
  ON public.sales_daily_sheets_import_batches
  FOR SELECT
  TO authenticated
  USING (created_by = auth.uid());

COMMENT ON TABLE public.sales_daily_sheets_import_batches IS
  'Audit log for Sales Daily Sheets uploads; RPC trigger_sales_daily_sheets_import inserts rows.';

GRANT SELECT ON public.sales_daily_sheets_import_batches TO authenticated;

-- ---------------------------------------------------------------------------
-- RPC: verify path, elevated role, storage object; record batch; return JSON for UI
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.trigger_sales_daily_sheets_import(p_storage_path text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, storage, auth, pg_temp
AS $$
DECLARE
  v_path text := trim(p_storage_path);
  v_uid uuid := auth.uid();
  v_batch_id uuid := gen_random_uuid();
  v_bucket_id text;
  v_found boolean;
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
    created_by
  )
  VALUES (
    v_batch_id,
    v_path,
    'registered',
    'Object verified in Storage. Hook your existing import job here to populate rows_staged / rows_loaded.',
    NULL,
    NULL,
    v_uid
  );

  -- Optional: call your existing import routine, e.g.:
  -- PERFORM private.your_sales_daily_import_worker(v_batch_id, v_path);

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Import batch registered. Connect your ETL or Edge Function to process the CSV.',
    'storage_path', v_path,
    'batch_id', v_batch_id,
    'rows_staged', NULL,
    'rows_loaded', NULL
  );
END;
$$;

REVOKE ALL ON FUNCTION public.trigger_sales_daily_sheets_import(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.trigger_sales_daily_sheets_import(text) TO authenticated;

-- RLS on storage.objects references this helper; it only reflects the caller's own role.
GRANT USAGE ON SCHEMA private TO authenticated;
GRANT EXECUTE ON FUNCTION private.user_has_elevated_access() TO authenticated;

-- ---------------------------------------------------------------------------
-- Storage RLS policies: elevated users only; paths under incoming/
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS sales_daily_sheets_objects_insert ON storage.objects;
CREATE POLICY sales_daily_sheets_objects_insert
  ON storage.objects
  FOR INSERT
  TO authenticated
  WITH CHECK (
    (SELECT private.user_has_elevated_access())
    AND bucket_id = 'sales-daily-sheets'
    AND name LIKE 'incoming/%'
    AND owner = auth.uid()
  );

DROP POLICY IF EXISTS sales_daily_sheets_objects_select ON storage.objects;
CREATE POLICY sales_daily_sheets_objects_select
  ON storage.objects
  FOR SELECT
  TO authenticated
  USING (
    (SELECT private.user_has_elevated_access())
    AND bucket_id = 'sales-daily-sheets'
    AND name LIKE 'incoming/%'
  );

DROP POLICY IF EXISTS sales_daily_sheets_objects_update ON storage.objects;
CREATE POLICY sales_daily_sheets_objects_update
  ON storage.objects
  FOR UPDATE
  TO authenticated
  USING (
    (SELECT private.user_has_elevated_access())
    AND bucket_id = 'sales-daily-sheets'
    AND name LIKE 'incoming/%'
    AND owner = auth.uid()
  )
  WITH CHECK (
    (SELECT private.user_has_elevated_access())
    AND bucket_id = 'sales-daily-sheets'
    AND name LIKE 'incoming/%'
    AND owner = auth.uid()
  );

DROP POLICY IF EXISTS sales_daily_sheets_objects_delete ON storage.objects;
CREATE POLICY sales_daily_sheets_objects_delete
  ON storage.objects
  FOR DELETE
  TO authenticated
  USING (
    (SELECT private.user_has_elevated_access())
    AND bucket_id = 'sales-daily-sheets'
    AND name LIKE 'incoming/%'
    AND owner = auth.uid()
  );
