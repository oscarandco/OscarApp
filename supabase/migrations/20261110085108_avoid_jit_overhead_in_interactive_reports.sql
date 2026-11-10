-- JIT compilation costs seconds on these interactive reports.
-- Scope this setting to read-only reporting entry points; retain timeouts and ACLs.
ALTER FUNCTION public.get_admin_payroll_summary_weekly() SET jit=off;
ALTER FUNCTION public.get_admin_payroll_lines_weekly(date) SET jit=off;
ALTER FUNCTION public.get_location_sales_summary_for_my_sales() SET jit=off;
ALTER FUNCTION public.get_contractor_invoice_batch(date,boolean) SET jit=off;
ALTER FUNCTION public.get_contractor_invoice_preview(date,uuid) SET jit=off;
ALTER FUNCTION public.get_payroll_cost_readiness(date) SET jit=off;
