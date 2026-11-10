-- Local Docker only. Fixtures, invoices and plan/cost changes roll back.
BEGIN;
SET LOCAL plpgsql.check_asserts=on;
SELECT set_config('request.jwt.claim.sub',id::text,true) FROM auth.users WHERE email='local-admin@oscarapp.test';
CREATE TEMP TABLE invoice_history_before AS SELECT id,to_jsonb(i) data FROM public.contractor_invoices i;
CREATE TEMP TABLE invoice_lines_before AS SELECT id,to_jsonb(i) data FROM public.contractor_invoice_lines i;
DO $tests$
DECLARE person public.staff_members; source public.sales_transactions; sale public.sales_transactions;
 token text:=replace(gen_random_uuid()::text,'-',''); person_id uuid:=gen_random_uuid(); plan_id uuid; service_id uuid;
 inv text; preview record; details jsonb; saved jsonb; invoice_id uuid; snapshot jsonb; failed boolean; amount numeric;
BEGIN
 ASSERT auth.uid() IS NOT NULL;
 SELECT * INTO STRICT person FROM public.staff_members WHERE lower(employment_type)='contractor' LIMIT 1;
 plan_id:=public.admin_save_remuneration_plan(NULL,'__INVOICE_PLAN_'||token,false,NULL,true,
  '{"retail_product":0.1,"professional_product":0.1,"service":0.45,"toner_with_other_service":0.1,"extensions_product":0.1,"extensions_service":0.45}'::jsonb);
 person.id:=person_id; person.full_name:='Invoice calculation test '||token; person.display_name:='Invoice test '||token;
 person.primary_location_id:=(SELECT id FROM public.locations ORDER BY id LIMIT 1);
 person.is_active:=true; person.employment_type:='Contractor'; person.remuneration_plan:='__INVOICE_PLAN_'||token;
 person.remuneration_plan_id:=plan_id; person.remuneration_plan_fallback_id:=plan_id;
 person.contractor_invoice_code:='TST'||left(token,6);person.contractor_gst_registered:=true;person.contractor_ird_number:='123456789';
 person.contractor_street_address:='1 Test Street';person.contractor_suburb:='Test suburb';person.contractor_city_postcode:='Test city 0000';
 INSERT INTO public.staff_members SELECT(person).*;
 inv:='__INVOICE_'||token;
 FOR source IN SELECT DISTINCT ON (kind) st.* FROM public.sales_transactions st
  CROSS JOIN LATERAL(SELECT CASE
   WHEN st.product_service_name ILIKE 'Foils (Half Head)%Master Colourist' THEN 1
   WHEN st.product_service_name='Cut and Blow Wave Creative Director' THEN 2
   WHEN st.product_service_name='All-Over Toner with Other Service (20-39g)*' THEN 3
   WHEN lower(st.product_service_name)='green fee' THEN 4 END kind) k
  WHERE k.kind IS NOT NULL ORDER BY kind,st.sale_date DESC
 LOOP
  sale:=source;sale.id:=gen_random_uuid();sale.raw_row_id:=NULL;sale.invoice:=inv;sale.customer_name:='Test Guest';
  sale.sale_date:=date '2026-11-05';sale.sale_datetime:='2026-11-05 12:00:00+13';sale.month_start:=date '2026-11-01';sale.month_num:=11;sale.quantity:=1;
  IF lower(source.product_service_name)='green fee' THEN sale.price_ex_gst:=2.61;
  ELSE
   sale.staff_commission_id:=person_id;sale.staff_work_id:=person_id;sale.staff_paid_id:=person_id;
   sale.staff_commission_name:=person.display_name;sale.staff_work_name:=person.display_name;sale.staff_paid_name:=person.display_name;
   IF source.product_service_name ILIKE 'Foils (Half Head)%Master Colourist' THEN
    sale.product_service_name:='__INVOICE_FOILS_'||token;sale.price_ex_gst:=228.70;
    service_id:=public.create_service_product_cost_service(sale.product_service_name);
    PERFORM public.save_service_product_costs(jsonb_build_array(jsonb_build_object('service_id',service_id,'unit_cost_ex_gst',15,'effective_from','2026-11-01')));
   ELSIF source.product_service_name='Cut and Blow Wave Creative Director' THEN
    sale.product_service_name:='__INVOICE_CUT_'||token;sale.price_ex_gst:=139.13;
    service_id:=public.create_service_product_cost_service(sale.product_service_name);
    PERFORM public.save_service_product_costs(jsonb_build_array(jsonb_build_object('service_id',service_id,'unit_cost_ex_gst',0,'effective_from','2026-11-01')));
   ELSE sale.price_ex_gst:=65.22;
   END IF;
  END IF;
  sale.price_incl_gst:=sale.price_ex_gst*1.15;sale.price_gst_component:=sale.price_ex_gst*0.15;
  -- One location keeps the source invoice tuple unambiguous.
  sale.location_id:=person.primary_location_id;
  INSERT INTO public.sales_transactions SELECT(sale).*;
  IF source.product_service_name='Cut and Blow Wave Creative Director' THEN
   sale.id:=gen_random_uuid();sale.invoice:=inv||'_SECOND';INSERT INTO public.sales_transactions SELECT(sale).*;
  END IF;
 END LOOP;
 SELECT * INTO STRICT preview FROM public.get_contractor_invoice_preview_v2(date '2026-11-02',person_id) WHERE source_invoice_number=inv;
 ASSERT preview.client_invoice_amount_ex_gst=433.05,'Eligible sales exclude green fee';
 ASSERT preview.product_cost_ex_gst=15 AND preview.commissionable_ex_gst=418.05,'Deduction and basis must match the actual payroll lines';
 ASSERT preview.contractor_amount_ex_gst=165.30 AND preview.payroll_subtotal_ex_gst=227.90,'Mixed rates and weekly rounding must reconcile';
 details:=public.get_contractor_source_invoice_calculation(inv,NULL,date '2026-11-05',person_id);
 ASSERT jsonb_array_length(details->'lines')=4 AND (details->>'customer_total_ex_gst')::numeric=435.66,'All customer lines must be visible';
 ASSERT (details->>'eligible_sales_ex_gst')::numeric=433.05 AND (details->>'contractor_fee_ex_gst')::numeric=165.30,'Detail must match preview';
 ASSERT EXISTS(SELECT 1 FROM jsonb_array_elements(details->'lines') l WHERE l->>'product_service_name'='Green fee' AND NOT(l->>'eligible')::boolean AND (l->>'contractor_fee_ex_gst')::numeric=0),'Green fee must be visibly excluded';
 saved:=public.create_contractor_invoice_v2(date '2026-11-02',person_id,NULL,NULL,NULL);invoice_id:=(saved->>'id')::uuid;
 ASSERT (SELECT subtotal_ex_gst=227.90 AND rounding_adjustment_ex_gst=-0.01 AND gst_amount=34.19 AND total_inc_gst=262.09 AND calculation_version=2 FROM public.contractor_invoices WHERE id=invoice_id),'Saved totals must reconcile to payroll plus GST';
 ASSERT (SELECT sum(contractor_amount_ex_gst) FROM public.contractor_invoice_lines WHERE contractor_invoice_id=invoice_id)=227.91,'Visible row amounts preserved';
 SELECT source_payload INTO snapshot FROM public.contractor_invoice_lines WHERE contractor_invoice_id=invoice_id AND source_invoice_number=inv;
 ASSERT snapshot->'detail'=details AND (snapshot->>'product_cost_ex_gst')::numeric=15,'Complete immutable calculation snapshot required';
 UPDATE public.sales_transactions SET price_ex_gst=price_ex_gst+10 WHERE invoice=inv AND product_service_name LIKE '__INVOICE_FOILS_%';
 ASSERT (SELECT source_payload FROM public.contractor_invoice_lines WHERE contractor_invoice_id=invoice_id AND source_invoice_number=inv)=snapshot,'Saved calculation must not follow live source changes';
 UPDATE public.sales_transactions SET price_ex_gst=price_ex_gst-10 WHERE invoice=inv AND product_service_name LIKE '__INVOICE_FOILS_%';
 ASSERT NOT EXISTS(SELECT id,data FROM invoice_history_before EXCEPT SELECT id,to_jsonb(i) FROM public.contractor_invoices i),'Existing invoice headers unchanged';
 ASSERT NOT EXISTS(SELECT id,data FROM invoice_lines_before EXCEPT SELECT id,to_jsonb(i) FROM public.contractor_invoice_lines i),'Existing invoice lines unchanged';
 PERFORM set_config('request.jwt.claim.sub','',true);
 failed:=false;BEGIN PERFORM public.get_contractor_source_invoice_calculation(inv,NULL,NULL,person_id);EXCEPTION WHEN insufficient_privilege THEN failed:=true;END;ASSERT failed,'Anonymous details denied';
 PERFORM set_config('request.jwt.claim.sub',(SELECT user_id::text FROM public.staff_member_user_access WHERE is_active AND access_role='stylist' LIMIT 1),true);
 ASSERT auth.uid() IS NOT NULL,'A non-admin fixture is required';
 failed:=false;BEGIN PERFORM public.get_contractor_source_invoice_calculation(inv,NULL,NULL,person_id);EXCEPTION WHEN insufficient_privilege THEN failed:=true;END;ASSERT failed,'Staff details denied';
 failed:=false;BEGIN PERFORM public.create_contractor_invoice_v2(date '2026-11-02',person_id,NULL,NULL,NULL);EXCEPTION WHEN insufficient_privilege THEN failed:=true;END;ASSERT failed,'Staff creation denied';
 RAISE NOTICE 'PASS: exclusions, mixed rates, deductions, exact rounding, GST, snapshots and anonymous denial';
END $tests$;
ROLLBACK;
