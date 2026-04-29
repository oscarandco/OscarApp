-- Location-level sales ex GST by pay week (all staff), for My Sales KPI cards.
-- Same line source as Sales Summary (v_admin_payroll_lines_weekly) but aggregated
-- per location × pay week so stylists are not limited to their own summary rows.

CREATE OR REPLACE FUNCTION public.get_location_sales_summary_for_my_sales()
RETURNS TABLE (
  pay_week_start date,
  pay_week_end date,
  pay_date date,
  location_id uuid,
  location_name text,
  total_sales_ex_gst numeric
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT
    l.pay_week_start,
    l.pay_week_end,
    l.pay_date,
    l.location_id,
    max(l.location_name)::text AS location_name,
    round(sum(coalesce(l.price_ex_gst, 0::numeric)), 2) AS total_sales_ex_gst
  FROM public.v_admin_payroll_lines_weekly l
  WHERE EXISTS (
    SELECT 1
    FROM public.staff_member_user_access a
    WHERE a.user_id = auth.uid()
      AND coalesce(a.is_active, false) = true
  )
  GROUP BY l.pay_week_start, l.pay_week_end, l.pay_date, l.location_id
  ORDER BY l.pay_week_start DESC NULLS LAST, l.location_id NULLS LAST;
$$;

ALTER FUNCTION public.get_location_sales_summary_for_my_sales() OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.get_location_sales_summary_for_my_sales() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_location_sales_summary_for_my_sales() TO service_role;
