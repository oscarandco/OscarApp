-- Run only through the local Docker test runner. All fixtures roll back.
-- Requires the restored OscarApp data and the completed service-cost migration.
BEGIN;
SET LOCAL plpgsql.check_asserts = on;
SET LOCAL statement_timeout = 0;
SELECT set_config('request.jwt.claim.sub', id::text, true),
       set_config('request.jwt.claims', jsonb_build_object('sub',id,'role','authenticated')::text, true)
FROM auth.users WHERE email='local-admin@oscarapp.test';
CREATE TEMP TABLE sc_original_money ON COMMIT DROP AS
 SELECT id,sale_date,price_ex_gst,actual_commission_rate,actual_commission_amt_ex_gst,
        theoretical_commission_rate,theoretical_commission_amt_ex_gst,
        assistant_commission_amt_ex_gst,theoretical_assistant_commission_amt_ex_gst,
        derived_staff_paid_id,derived_staff_paid_plan_id,commission_category_final
 FROM public.v_commission_calculations_core;
CREATE TEMP TABLE sc_snapshot_digests ON COMMIT DROP AS
 SELECT 'headers'::text kind,md5(string_agg(to_jsonb(i)::text,'' ORDER BY id)) digest FROM public.contractor_invoices i
 UNION ALL SELECT 'lines',md5(string_agg(to_jsonb(i)::text,'' ORDER BY id)) FROM public.contractor_invoice_lines i;

DO $tests$
DECLARE
  source public.sales_transactions;
  fixture public.sales_transactions;
  wage_fixture public.sales_transactions;
  assistant_fixture public.sales_transactions;
  retail_fixture public.sales_transactions;
  paid public.staff_members;
  wage public.staff_members;
  assistant_staff public.staff_members;
  sid uuid; zero_sid uuid; gap_sid uuid; plan_id uuid;
  gap_ids uuid[]:=ARRAY[]::uuid[]; gap_count bigint; gap_key_count bigint;
  line_id uuid:=gen_random_uuid(); wage_id uuid:=gen_random_uuid();
  assistant_id uuid:=gen_random_uuid(); retail_id uuid:=gen_random_uuid();
  case_row record; b record; c record; saved record;
  original_example numeric;
  count_before bigint;
  failed boolean;
  current_admin text:=auth.uid()::text;
  plan_name text:='__SC_TEST_PLAN_'||gen_random_uuid()::text;
BEGIN
  ASSERT current_admin IS NOT NULL, 'Local test admin fixture is missing';
  ASSERT (SELECT max(sale_date) FROM public.sales_transactions)<DATE '2026-11-01',
    'This harness expects the unchanged pre-November source snapshot';
  SELECT st.* INTO STRICT source FROM public.sales_transactions st
  WHERE st.id=(SELECT x.id FROM public.v_commission_calculations_core x
    WHERE x.invoice='INV98610' AND x.product_service_name='Colour Root Retouch Emerging Colourist'
    AND x.sale_date=DATE '2026-10-30' LIMIT 1);
  SELECT actual_commission_amt_ex_gst INTO original_example
    FROM public.v_commission_calculations_core WHERE id=source.id;
  ASSERT round(original_example,2)=52.35,'SC02 source October example must start at $52.35';
  SELECT sm.* INTO STRICT paid FROM public.staff_members sm WHERE sm.id=(
    SELECT derived_staff_paid_id FROM public.v_commission_calculations_core WHERE id=source.id);
  sid:=private.service_id_for_sale(source.raw_row_id,source.location_id,source.product_service_name);
  ASSERT sid IS NOT NULL,'Service discovery must recognise the original eligible service';

  plan_id:=public.admin_save_remuneration_plan(NULL,plan_name,true,NULL,true,
    '{"retail_product":0.1,"professional_product":0.1,"service":0.35,"toner_with_other_service":0.1,"extensions_product":0.1,"extensions_service":0.35}'::jsonb);
  PERFORM public.apply_staff_role_assignment(
    p_staff_member_id=>paid.id,p_effective_start_date=>DATE '2026-11-01',
    p_primary_role=>paid.primary_role,p_secondary_roles=>paid.secondary_roles,
    p_employment_type=>paid.employment_type,p_remuneration_plan=>plan_name,
    p_fte=>paid.fte,p_primary_location_id=>paid.primary_location_id,
    p_reason=>'Transaction-scoped product cost regression fixture',p_remuneration_plan_id=>plan_id);
  PERFORM public.admin_set_theoretical_benchmark(plan_id,DATE '2026-11-01');

  fixture:=source; fixture.id:=line_id; fixture.raw_row_id:=NULL;
  fixture.invoice:='__SC_TEST_POSITIVE';fixture.customer_name:='Local test fixture';
  fixture.sale_date:=DATE '2026-11-01';fixture.sale_datetime:='2026-11-01 12:00:00+13';
  fixture.month_start:=DATE '2026-11-01';fixture.month_num:=11;
  fixture.quantity:=1;fixture.price_ex_gst:=149.57;fixture.price_incl_gst:=172.0055;fixture.price_gst_component:=22.4355;
  INSERT INTO public.sales_transactions SELECT (fixture).*;
  ASSERT EXISTS(SELECT 1 FROM public.get_payroll_cost_readiness(DATE '2026-10-26') r
    WHERE r.service_id=sid AND r.reason='missing_cost'), 'SC13 November fixture must require a cost';
  failed:=false;
  BEGIN
    PERFORM actual_commission_amt_ex_gst FROM public.v_commission_calculations_core WHERE id=line_id;
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    ASSERT SQLERRM LIKE 'Commission awaiting product costs%','Unexpected commission readiness error: '||SQLERRM; failed:=true;
  END;
  ASSERT failed,'SC07 missing cost must never become an apparently complete amount';
  failed:=false;
  BEGIN
    PERFORM * FROM public.get_admin_payroll_summary_weekly();
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    ASSERT SQLERRM LIKE 'Commission awaiting product costs%','Unexpected report readiness error: '||SQLERRM; failed:=true;
  END;
  ASSERT failed,'SC13 alternate reporting RPC must reject incomplete commission totals';

  PERFORM public.save_service_product_costs(jsonb_build_array(jsonb_build_object(
    'service_id',sid,'unit_cost_ex_gst',30,'effective_from','2026-11-01')));
  ASSERT NOT EXISTS(SELECT 1 FROM public.get_payroll_cost_readiness(DATE '2026-10-26') r WHERE r.service_id=sid),
    'SC14 saving dated cost must resolve the selected-week requirement';
  SELECT * INTO c FROM public.v_commission_calculations_core WHERE id=line_id;
  ASSERT c.actual_commission_amt_ex_gst=119.57*0.35 AND c.theoretical_commission_amt_ex_gst=119.57*0.35,
    'SC03 actual/theoretical commission must use $119.57 basis';
  ASSERT c.price_ex_gst=149.57 AND round(c.actual_commission_amt_ex_gst,2)=41.85,
    'SC03 price remains unchanged and displayed commission is $41.85';
  SELECT (section->'example'->>'commission')::numeric INTO original_example
    FROM jsonb_array_elements(public.get_staff_commission_guide(paid.id,DATE '2026-11-01')->'eligible_sections') section
    WHERE section->>'category'='service';
  ASSERT original_example=41.85,'Commission guide must use the same dated product-cost basis';
  SELECT actual_commission_amt_ex_gst INTO original_example FROM public.v_commission_calculations_core WHERE id=source.id;
  ASSERT (SELECT actual_commission_amt_ex_gst FROM public.v_commission_calculations_core WHERE id=source.id)=original_example,
    'SC08 November plan must not alter October lines in the same pay week';

  -- Exercise the signed numeric basis directly, independently of report rounding.
  FOR case_row IN SELECT * FROM (VALUES
    (149.57::numeric,1::numeric,119.57::numeric,30::numeric,'one unit'),
    (299.14,2,239.14,60,'two units'),
    (120,1,90,30,'discount'),
    (20,1,0,30,'cost exceeds sale'),
    (30,1,0,30,'cost equals sale'),
    (0,1,0,30,'complimentary'),
    (-149.57,-1,-119.57,-30,'full credit'),
    (-299.14,-2,-239.14,-60,'two-unit credit'),
    (-20,-1,0,-30,'credit mirrors zero commission')
  ) t(amount,quantity,expected_basis,expected_cost,label) LOOP
    SELECT * INTO b FROM private.service_commission_basis(sid,DATE '2026-11-01',case_row.amount,case_row.quantity,true,true,true,true);
    ASSERT b.service_cost_status='ready',case_row.label||' should be ready';
    ASSERT b.actual_commissionable_ex_gst=case_row.expected_basis AND b.theoretical_commissionable_ex_gst=case_row.expected_basis,
      case_row.label||' commission basis mismatch';
    ASSERT b.actual_product_cost_ex_gst=case_row.expected_cost,case_row.label||' signed unit-cost mismatch';
  END LOOP;

  UPDATE public.sales_transactions SET quantity=2,price_ex_gst=299.14 WHERE id=line_id;
  ASSERT (SELECT round(actual_commission_amt_ex_gst,2) FROM public.v_commission_calculations_core WHERE id=line_id)=83.70,
    'SC04 quantity two must deduct twice, without multiplying imported revenue twice';
  UPDATE public.sales_transactions SET quantity=-1,price_ex_gst=-149.57 WHERE id=line_id;
  ASSERT (SELECT round(actual_commission_amt_ex_gst,2) FROM public.v_commission_calculations_core WHERE id=line_id)=-41.85,
    'SC16 full matching credit must remain negative';
  UPDATE public.sales_transactions SET quantity=1,price_ex_gst=149.57 WHERE id=line_id;

  -- Independent actual/theoretical settings: a Wage stylist keeps actual zero.
  SELECT sm.* INTO wage FROM public.staff_members sm JOIN public.remuneration_plans p ON p.id=sm.remuneration_plan_id
    WHERE lower(btrim(p.plan_name))='wage' AND sm.is_active AND coalesce(lower(sm.primary_role),'')<>'assistant' LIMIT 1;
  ASSERT wage.id IS NOT NULL,'Expected an active Wage fixture in the restored source';
  wage_fixture:=fixture; wage_fixture.id:=wage_id;wage_fixture.invoice:='__SC_TEST_WAGE';
  wage_fixture.staff_commission_name:=wage.display_name;wage_fixture.staff_work_name:=wage.display_name;wage_fixture.staff_paid_name:=wage.display_name;
  wage_fixture.staff_commission_id:=wage.id;wage_fixture.staff_work_id:=wage.id;wage_fixture.staff_paid_id:=wage.id;
  INSERT INTO public.sales_transactions SELECT (wage_fixture).*;
  SELECT * INTO c FROM public.v_commission_calculations_core WHERE id=wage_id;
  ASSERT c.derived_staff_paid_id=wage.id AND c.actual_commission_amt_ex_gst=0 AND round(c.theoretical_commission_amt_ex_gst,2)=41.85,
    'SC09 actual Wage must remain zero while theoretical uses November benchmark';
  UPDATE public.sales_transactions SET sale_date=DATE '2026-10-31',sale_datetime='2026-10-31 12:00:00+13' WHERE id=wage_id;
  ASSERT (SELECT round(theoretical_commission_amt_ex_gst,2) FROM public.v_commission_calculations_core WHERE id=wage_id)=52.35,
    'SC09 historical theoretical commission must retain the old benchmark';

  -- Service work by an assistant uses the same adjusted basis exactly once.
  SELECT * INTO assistant_staff FROM public.staff_members WHERE lower(btrim(primary_role))='assistant' AND is_active LIMIT 1;
  ASSERT assistant_staff.id IS NOT NULL,'Expected an active assistant fixture';
  assistant_fixture:=fixture;assistant_fixture.id:=assistant_id;assistant_fixture.invoice:='__SC_TEST_ASSISTANT';
  assistant_fixture.staff_work_id:=assistant_staff.id;assistant_fixture.staff_work_name:=assistant_staff.display_name;
  assistant_fixture.staff_work_type:='Assistant';assistant_fixture.staff_work_is_staff_paid:='No';
  INSERT INTO public.sales_transactions SELECT (assistant_fixture).*;
  SELECT * INTO c FROM public.v_commission_calculations_core WHERE id=assistant_id;
  ASSERT c.derived_staff_paid_id=paid.id AND round(c.assistant_commission_amt_ex_gst,2)=41.85
    AND round(c.theoretical_assistant_commission_amt_ex_gst,2)=41.85,
    'SC18 assistant and theoretical-assistant paths must use the cost-adjusted basis once';

  -- Retail/Professional classifications retain their existing basis despite enabled plans.
  SELECT st.* INTO retail_fixture FROM public.sales_transactions st JOIN public.v_commission_calculations_core x ON x.id=st.id
    WHERE x.commission_category_final='retail_product' AND x.price_ex_gst>0 LIMIT 1;
  ASSERT retail_fixture.id IS NOT NULL,'Expected a Retail fixture';
  retail_fixture.id:=retail_id;retail_fixture.raw_row_id:=NULL;retail_fixture.invoice:='__SC_TEST_RETAIL';
  retail_fixture.sale_date:=DATE '2026-11-01';retail_fixture.sale_datetime:='2026-11-01 12:00:00+13';
  retail_fixture.quantity:=1;retail_fixture.price_ex_gst:=149.57;
  retail_fixture.staff_commission_id:=paid.id;retail_fixture.staff_work_id:=paid.id;retail_fixture.staff_paid_id:=paid.id;
  retail_fixture.staff_commission_name:=paid.display_name;retail_fixture.staff_work_name:=paid.display_name;retail_fixture.staff_paid_name:=paid.display_name;
  INSERT INTO public.sales_transactions SELECT (retail_fixture).*;
  SELECT * INTO c FROM public.v_commission_calculations_core WHERE id=retail_id;
  ASSERT c.service_cost_status='not_required' AND c.actual_commission_amt_ex_gst=149.57*0.1,
    'SC15 Retail must not receive a service-cost deduction or missing-cost gate';

  -- Explicit zero remains distinct from a required cost that is absent.
  zero_sid:=public.create_service_product_cost_service('__SC_TEST_ZERO_'||gen_random_uuid()::text);
  SELECT * INTO b FROM private.service_commission_basis(zero_sid,DATE '2026-11-01',149.57,1,true,true,true,true);
  ASSERT b.service_cost_status='missing_cost' AND b.actual_commissionable_ex_gst IS NULL,'SC07 unconfigured cannot mean zero';
  PERFORM public.save_service_product_costs(jsonb_build_array(jsonb_build_object('service_id',zero_sid,'unit_cost_ex_gst',0,'effective_from','2026-11-01')));
  SELECT * INTO b FROM private.service_commission_basis(zero_sid,DATE '2026-11-01',149.57,1,true,true,true,true);
  ASSERT b.service_cost_status='ready' AND b.actual_product_cost_ex_gst=0 AND b.actual_commissionable_ex_gst=149.57,'SC07 explicit zero is ready';
  FOR case_row IN SELECT * FROM (VALUES (NULL::numeric),(0::numeric),(-1::numeric)) q(quantity) LOOP
    SELECT * INTO b FROM private.service_commission_basis(sid,DATE '2026-11-01',149.57,case_row.quantity,true,true,true,true);
    ASSERT b.service_cost_status='invalid_quantity' AND b.actual_commissionable_ex_gst IS NULL,'SC19 missing/zero/inconsistent quantity must be unresolved';
  END LOOP;
  SELECT * INTO b FROM private.service_commission_basis(NULL,DATE '2026-11-01',149.57,1,true,true,true,true);
  ASSERT b.service_cost_status='missing_service','SC19 unknown source identity must be unresolved';
  SELECT * INTO b FROM private.service_commission_basis(sid,DATE '2026-11-01',149.57,1,true,true,true,false);
  ASSERT b.service_cost_status='missing_benchmark','Missing benchmark must never silently mean zero';

  -- New versions close earlier inclusive intervals without rewriting old unit cost.
  PERFORM public.save_service_product_costs(jsonb_build_array(jsonb_build_object('service_id',sid,'unit_cost_ex_gst',40,'effective_from','2026-11-10')));
  SELECT * INTO b FROM private.service_commission_basis(sid,DATE '2026-11-09',149.57,1,true,true,true,true);
  ASSERT b.actual_product_cost_ex_gst=30,'SC11 older date retains prior cost';
  SELECT * INTO b FROM private.service_commission_basis(sid,DATE '2026-11-10',149.57,1,true,true,true,true);
  ASSERT b.actual_product_cost_ex_gst=40 AND b.actual_commissionable_ex_gst=109.57,'SC11 new date uses next cost';
  ASSERT EXISTS(SELECT 1 FROM public.service_product_cost_versions WHERE service_id=sid AND effective_from='2026-11-01' AND effective_to='2026-11-09' AND unit_cost_ex_gst=30),'Inclusive cost intervals must not overlap';
  failed:=false;
  BEGIN PERFORM public.save_service_product_costs(jsonb_build_array(jsonb_build_object('service_id',sid,'unit_cost_ex_gst',31,'effective_from','2026-11-01')));
  EXCEPTION WHEN SQLSTATE 'P0001' THEN failed:=true; END;
  ASSERT failed,'SC11 an existing cost version must not be overwritten';
  SELECT count(*) INTO count_before FROM public.service_product_cost_versions;
  failed:=false;
  BEGIN PERFORM public.save_service_product_costs(jsonb_build_array(
    jsonb_build_object('service_id',zero_sid,'unit_cost_ex_gst',1,'effective_from','2026-12-01'),
    jsonb_build_object('service_id',NULL,'unit_cost_ex_gst',-1,'effective_from','2026-12-01')));
  EXCEPTION WHEN OTHERS THEN failed:=true; END;
  ASSERT failed AND (SELECT count(*) FROM public.service_product_cost_versions)=count_before,'SC20 cost batches must be atomic on invalid input';

  -- Usage comes from transaction dates. A fixture in another salon shares its cost.
  UPDATE public.sales_transactions SET location_id=(SELECT id FROM public.locations WHERE id<>fixture.location_id LIMIT 1) WHERE id=line_id;
  SELECT * INTO c FROM public.v_commission_calculations_core WHERE id=line_id;
  ASSERT round(c.actual_commission_amt_ex_gst,2)=41.85,'SC12 cost must be shared across salons';
  SELECT * INTO saved FROM public.get_service_product_costs(DATE '2026-11-01') WHERE service_id=sid;
  ASSERT saved.seen_in_sales AND saved.last_sale_date=DATE '2026-11-01','SC21 usage must reflect transaction date, not current/upload date';
  PERFORM public.set_service_product_cost_service_active(sid,false);
  ASSERT (SELECT round(actual_commission_amt_ex_gst,2) FROM public.v_commission_calculations_core WHERE id=line_id)=41.85,'Archived service must retain historical cost resolution';

  -- Separate missing intervals in one week must not collapse into one row.
  gap_sid:=public.create_service_product_cost_service('__SC_TEST_GAPS_'||gen_random_uuid()::text);
  INSERT INTO public.service_product_cost_versions(service_id,unit_cost_ex_gst,effective_from,effective_to)
    VALUES(gap_sid,10,DATE '2026-11-04',DATE '2026-11-04');
  FOR case_row IN SELECT * FROM (VALUES
    (DATE '2026-11-02'),(DATE '2026-11-04'),(DATE '2026-11-06')
  ) gap(sale_day) LOOP
    fixture.id:=gen_random_uuid();gap_ids:=array_append(gap_ids,fixture.id);
    fixture.sale_date:=case_row.sale_day;fixture.sale_datetime:=case_row.sale_day::timestamp AT TIME ZONE 'Pacific/Auckland';
    fixture.product_service_name:=(SELECT service_name FROM public.service_product_cost_services WHERE id=gap_sid);
    fixture.product_master_id:=NULL;fixture.invoice:='__SC_TEST_GAP_'||case_row.sale_day::text;
    INSERT INTO public.sales_transactions SELECT(fixture).*;
  END LOOP;
  SELECT count(*),count(DISTINCT issue_key) INTO gap_count,gap_key_count
    FROM public.get_payroll_cost_readiness(DATE '2026-11-02') WHERE service_id=gap_sid;
  ASSERT gap_count=2 AND gap_key_count=2,
    'SC13 separate missing intervals in a week must yield two distinct requirements for one service';
  ASSERT EXISTS(SELECT 1 FROM public.get_payroll_cost_readiness(DATE '2026-11-02')
    WHERE service_id=gap_sid AND first_sale_date=DATE '2026-11-02' AND last_sale_date=DATE '2026-11-02')
    AND EXISTS(SELECT 1 FROM public.get_payroll_cost_readiness(DATE '2026-11-02')
    WHERE service_id=gap_sid AND first_sale_date=DATE '2026-11-06' AND last_sale_date=DATE '2026-11-06'),
    'SC13 resolved middle date must separate the two unresolved cost intervals';
  DELETE FROM public.sales_transactions WHERE id=ANY(gap_ids);

  -- Earlier source calculations and saved invoice snapshots stay untouched.
  ASSERT NOT EXISTS(SELECT * FROM sc_original_money EXCEPT SELECT original_row.id,original_row.sale_date,original_row.price_ex_gst,original_row.actual_commission_rate,original_row.actual_commission_amt_ex_gst,original_row.theoretical_commission_rate,original_row.theoretical_commission_amt_ex_gst,original_row.assistant_commission_amt_ex_gst,original_row.theoretical_assistant_commission_amt_ex_gst,original_row.derived_staff_paid_id,original_row.derived_staff_paid_plan_id,original_row.commission_category_final FROM public.v_commission_calculations_core original_row JOIN sc_original_money o ON o.id=original_row.id),
    'SC01 all original monetary results/categories/paid identities must remain unchanged';
  ASSERT (SELECT digest FROM sc_snapshot_digests WHERE kind='headers') IS NOT DISTINCT FROM (SELECT md5(string_agg(to_jsonb(i)::text,'' ORDER BY id)) FROM public.contractor_invoices i), 'SC17 saved invoice headers must stay unchanged';
  ASSERT (SELECT digest FROM sc_snapshot_digests WHERE kind='lines') IS NOT DISTINCT FROM (SELECT md5(string_agg(to_jsonb(i)::text,'' ORDER BY id)) FROM public.contractor_invoice_lines i), 'SC17 saved invoice line snapshots must stay unchanged';

  ASSERT NOT has_table_privilege('authenticated','public.service_product_cost_versions','INSERT'), 'Cost writes must use authorised RPCs';
  ASSERT NOT has_function_privilege('anon','public.save_service_product_costs(jsonb)','EXECUTE'), 'Anon must not invoke cost writes';
  PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',auth.uid(),'role','authenticated')::text,true);
  failed:=false;
  BEGIN PERFORM public.create_service_product_cost_service('__SC_UNAUTHORISED'); EXCEPTION WHEN insufficient_privilege THEN failed:=true; END;
  ASSERT failed,'SC20 unmapped authenticated user must not manage costs';
  PERFORM set_config('request.jwt.claim.sub',current_admin,true);
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',current_admin,'role','authenticated')::text,true);
  RAISE NOTICE 'PASS: service costs numeric, dated actual/theoretical, signed credits, assistant, zero/missing, interval, shared-salon, permissions and snapshot checks';
END;
$tests$;
SELECT 'PASS: service-cost regression assertions; rolling back every fixture' AS result;
ROLLBACK;
