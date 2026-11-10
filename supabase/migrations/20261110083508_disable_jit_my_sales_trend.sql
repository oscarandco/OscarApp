-- Avoid JIT compilation overhead for this interactive personal report.
ALTER FUNCTION public.get_my_sales_trend_weekly() SET jit=off;
