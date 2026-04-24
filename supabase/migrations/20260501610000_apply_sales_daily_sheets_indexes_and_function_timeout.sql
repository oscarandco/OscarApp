-- Sales Daily Sheets apply pipeline: belt-and-braces statement_timeout + missing indexes.
--
-- Symptom: apply_sales_daily_sheets_to_payroll(uuid) raised
--   "canceling statement due to statement timeout"
-- on a 64,000-row import even though the body already calls
--   PERFORM set_config('statement_timeout', '0', true);
--
-- Root causes (in order of likely impact):
--
-- 1. The location-scoped DELETEs against public.sales_transactions
--    (`WHERE st.import_batch_id = b.id ...` and `WHERE st.import_batch_id = v_payroll_id`)
--    have NO supporting btree index on sales_transactions(import_batch_id).
--    Every apply forces a sequential scan over the full transactions table,
--    which grows month over month and is the most likely real timeout cause.
--
-- 2. load_raw_sales_rows_to_transactions(uuid) is plain LANGUAGE plpgsql with
--    no function-attribute `SET statement_timeout`. While the parent apply
--    function does set it transaction-locally, function-attribute SET is the
--    canonical way to guarantee the GUC is in effect from function entry,
--    surviving any pool/role-level resets.
--
-- 3. The per-row `staff_members` scalar subqueries in
--    load_raw_sales_rows_to_transactions match on
--    `lower(trim(sm.display_name))` with no expression index. Small table,
--    but at 60K rows this still adds avoidable CPU.
--
-- This migration adds the indexes and pins statement_timeout = 0 at the
-- function-attribute level on both apply RPCs. No business logic changes.

-- 1) Pin statement_timeout to 0 as a function attribute on the apply RPCs.
ALTER FUNCTION public.apply_sales_daily_sheets_to_payroll(uuid)
  SET statement_timeout TO '0';

ALTER FUNCTION public.load_raw_sales_rows_to_transactions(uuid)
  SET statement_timeout TO '0';

-- 2) Critical: index sales_transactions on import_batch_id so the
--    location-scoped DELETEs and the per-payroll-batch preclear DELETE
--    can use an index lookup instead of a sequential scan.
CREATE INDEX IF NOT EXISTS idx_sales_transactions_import_batch_id
  ON public.sales_transactions (import_batch_id);

-- 3) Helpful: index sales_import_batches on the join-filter columns used by
--    the location-scoped purge (source_name + location_id).
CREATE INDEX IF NOT EXISTS idx_sales_import_batches_source_location
  ON public.sales_import_batches (source_name, location_id);

-- 4) Modest: expression index used by the per-row staff lookups inside
--    load_raw_sales_rows_to_transactions. Partial on is_active=true, which
--    matches the subqueries' WHERE clauses.
CREATE INDEX IF NOT EXISTS idx_staff_members_lower_trim_display_name_active
  ON public.staff_members ((lower(btrim(display_name))))
  WHERE is_active = true;

-- 5) Refresh planner stats so the new indexes are picked up immediately.
ANALYZE public.sales_transactions;
ANALYZE public.sales_import_batches;
ANALYZE public.staff_members;
