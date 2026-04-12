-- Edge Function uses its own connection: it cannot see the batch row until the RPC transaction commits.
-- Dropping the FK lets staging inserts succeed while keeping batch_id NOT NULL and indexed.

ALTER TABLE public.sales_daily_sheets_staged_rows
  DROP CONSTRAINT IF EXISTS sales_daily_sheets_staged_rows_batch_id_fkey;

-- If the FK was auto-named differently on a given database, remove any FK from this table to import batches.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT c.conname AS name
    FROM pg_constraint c
    JOIN pg_class rel ON rel.oid = c.conrelid
    JOIN pg_namespace nsp ON nsp.oid = rel.relnamespace
    JOIN pg_class frel ON frel.oid = c.confrelid
    JOIN pg_namespace fnsp ON fnsp.oid = frel.relnamespace
    WHERE nsp.nspname = 'public'
      AND rel.relname = 'sales_daily_sheets_staged_rows'
      AND c.contype = 'f'
      AND fnsp.nspname = 'public'
      AND frel.relname = 'sales_daily_sheets_import_batches'
  LOOP
    EXECUTE format(
      'ALTER TABLE public.sales_daily_sheets_staged_rows DROP CONSTRAINT %I',
      r.name
    );
  END LOOP;
END
$$;

COMMENT ON COLUMN public.sales_daily_sheets_staged_rows.batch_id IS
  'Logical link to sales_daily_sheets_import_batches.id. No FK: Edge runs outside the RPC transaction that inserts the batch.';
