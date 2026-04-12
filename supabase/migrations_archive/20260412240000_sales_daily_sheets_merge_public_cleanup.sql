-- Remove legacy public merge helper if present (superseded by private.run_sales_daily_sheets_merge_if_installed).
DROP FUNCTION IF EXISTS public.run_sales_daily_sheets_merge_if_installed(uuid);
