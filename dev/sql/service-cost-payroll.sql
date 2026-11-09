CREATE FUNCTION public.get_payroll_cost_weeks() RETURNS TABLE(pay_week_start date) LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NOT private.user_has_page_access('weekly_payroll','view') THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT DISTINCT date_trunc('week',st.sale_date)::date FROM public.sales_transactions st ORDER BY 1 DESC;
END $$;

CREATE FUNCTION public.get_payroll_cost_sales(p_pay_week_start date) RETURNS TABLE(total_sales_ex_gst numeric,orewa_sales_ex_gst numeric,takapuna_sales_ex_gst numeric) LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NOT private.user_has_page_access('weekly_payroll','view') THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 RETURN QUERY SELECT coalesce(sum(st.price_ex_gst),0),coalesce(sum(st.price_ex_gst) FILTER(WHERE lower(l.name) LIKE '%orewa%'),0),coalesce(sum(st.price_ex_gst) FILTER(WHERE lower(l.name) LIKE '%takapuna%'),0)
 FROM public.sales_transactions st LEFT JOIN public.locations l ON l.id=st.location_id WHERE st.sale_date>=p_pay_week_start AND st.sale_date<p_pay_week_start+7;
END $$;

CREATE FUNCTION public.get_payroll_cost_readiness(p_pay_week_start date)
 RETURNS TABLE(issue_key text,service_id uuid,service_name text,first_sale_date date,last_sale_date date,affected_units numeric,reason text,suggested_effective_from date)
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF NOT private.user_has_page_access('weekly_payroll','view') THEN RAISE EXCEPTION 'Access denied' USING ERRCODE='42501'; END IF;
 PERFORM private.discover_service_product_costs();
 RETURN QUERY WITH unresolved AS (
 SELECT c.service_cost_service_id sid,c.product_service_name,c.sale_date,c.quantity,c.service_cost_status status,
 CASE WHEN c.service_cost_status='missing_cost' THEN coalesce((SELECT max(v.effective_to) FROM public.service_product_cost_versions v WHERE v.service_id=c.service_cost_service_id AND v.effective_to<c.sale_date),DATE '0001-01-01') END gap_anchor
 FROM public.v_commission_calculations_core c WHERE c.sale_date>=p_pay_week_start AND c.sale_date<p_pay_week_start+7 AND c.service_cost_status NOT IN ('ready','not_required'))
 SELECT coalesce(u.sid::text,min(u.product_service_name))||':'||u.status||':'||coalesce(u.gap_anchor::text,'')||':'||min(u.sale_date)::text,u.sid,coalesce(s.service_name,min(u.product_service_name)),
 min(u.sale_date),max(u.sale_date),sum(abs(u.quantity))::numeric,u.status,min(u.sale_date)
 FROM unresolved u LEFT JOIN public.service_product_cost_services s ON s.id=u.sid GROUP BY u.sid,s.service_name,u.status,u.gap_anchor,CASE WHEN u.sid IS NULL THEN u.product_service_name END ORDER BY 3,4;
END $$;

DO $$ DECLARE f regprocedure; BEGIN
 FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
 AND p.proname IN ('get_payroll_cost_weeks','get_payroll_cost_sales','get_payroll_cost_readiness') LOOP
 EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon',f); EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',f); END LOOP;
END $$;
