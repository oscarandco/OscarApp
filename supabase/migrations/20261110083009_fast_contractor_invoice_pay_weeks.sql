-- Listing dates must not calculate payroll or commission amounts.
CREATE OR REPLACE FUNCTION public.list_contractor_invoice_pay_weeks()
RETURNS TABLE(pay_week_start date,pay_week_end date)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'Not authenticated' USING ERRCODE='42501'; END IF;
 IF NOT private.user_has_page_access('contractor_invoices','view') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT u.week_start,u.week_end FROM (
  SELECT DISTINCT date_trunc('week',st.sale_date::timestamp)::date AS week_start,
   date_trunc('week',st.sale_date::timestamp)::date+6 AS week_end FROM public.sales_transactions st
  UNION SELECT ci.pay_week_start,ci.pay_week_end FROM public.contractor_invoices ci
 ) u ORDER BY u.week_start DESC;
END;
$$;
