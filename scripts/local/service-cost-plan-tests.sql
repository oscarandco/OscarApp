-- Run after the feature migration. All fixtures and renames roll back.
BEGIN;
SELECT set_config('request.jwt.claims', jsonb_build_object('sub',user_id,'role','authenticated')::text,true)
FROM public.staff_member_user_access WHERE access_role='admin' AND is_active LIMIT 1;
DO $tests$
DECLARE
  v_old uuid; v_new uuid; v_staff public.staff_members; v_rates jsonb; v_result jsonb;
  v_original_date date; v_denied boolean;
BEGIN
  SELECT id INTO STRICT v_old FROM public.remuneration_plans WHERE lower(btrim(plan_name))='commission';
  SELECT * INTO STRICT v_staff FROM public.staff_members WHERE remuneration_plan_id=v_old AND id IN
    (SELECT staff_member_id FROM public.staff_role_assignments WHERE effective_end_date IS NULL AND effective_start_date<'2026-11-01') LIMIT 1;
  SELECT min(effective_start_date)-1 INTO v_original_date FROM public.staff_role_assignments WHERE staff_member_id=v_staff.id;
  IF private.staff_plan_id_at(v_staff.id,v_original_date) IS DISTINCT FROM v_old THEN RAISE EXCEPTION 'Plan gap baseline must use frozen fallback'; END IF;
  v_new:=public.admin_duplicate_remuneration_plan(v_old,'__cost_test_new_commission');
  SELECT jsonb_object_agg(commission_category,rate) INTO v_rates FROM public.remuneration_plan_rates WHERE remuneration_plan_id=v_old;
  IF (SELECT jsonb_object_agg(commission_category,rate) FROM public.remuneration_plan_rates WHERE remuneration_plan_id=v_new) IS DISTINCT FROM v_rates THEN
    RAISE EXCEPTION 'Duplicating a plan did not copy every rate'; END IF;
  PERFORM public.admin_save_remuneration_plan(v_old,'__cost_test_commission_to_31_oct',
    (SELECT can_use_assistants FROM public.remuneration_plans WHERE id=v_old),NULL,false,v_rates);
  PERFORM public.admin_save_remuneration_plan(v_new,'Commission',
    (SELECT can_use_assistants FROM public.remuneration_plans WHERE id=v_old),NULL,true,v_rates);
  PERFORM public.admin_set_remuneration_plan_active(v_old,false);
  v_result:=public.apply_staff_role_assignment(v_staff.id,'2026-11-01',v_staff.primary_role,v_staff.secondary_roles,
    v_staff.employment_type,'Commission',v_staff.fte,v_staff.primary_location_id,'service-cost test',v_new);
  IF private.staff_plan_id_at(v_staff.id,'2026-10-30') IS DISTINCT FROM v_old OR
    private.staff_plan_id_at(v_staff.id,'2026-11-01') IS DISTINCT FROM v_new OR
    private.staff_plan_id_at(v_staff.id,v_original_date) IS DISTINCT FROM v_old THEN
    RAISE EXCEPTION 'Name reuse or staff assignment changed historical plan identity'; END IF;
  PERFORM public.admin_set_theoretical_benchmark(v_new,'2026-11-01');
  IF private.benchmark_plan_id_at('2026-10-31') IS DISTINCT FROM v_old OR
    private.benchmark_plan_id_at('2026-11-01') IS DISTINCT FROM v_new THEN
    RAISE EXCEPTION 'Theoretical benchmark cutover boundary is incorrect'; END IF;
  v_denied:=false;
  BEGIN UPDATE public.remuneration_plan_rates SET rate=rate+0.01 WHERE remuneration_plan_id=v_old AND commission_category='service';
  EXCEPTION WHEN check_violation THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Used plan rate changes were not blocked'; END IF;
  v_denied:=false;
  BEGIN UPDATE public.remuneration_plans SET deduct_service_product_costs=true WHERE id=v_old;
  EXCEPTION WHEN check_violation THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Used plan calculation-setting changes were not blocked'; END IF;
  v_denied:=false;
  BEGIN PERFORM public.admin_delete_remuneration_plan_if_unused(v_old);
  EXCEPTION WHEN check_violation THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Historical plan deletion was not blocked'; END IF;
  v_denied:=false;
  BEGIN PERFORM public.apply_staff_role_assignment(v_staff.id,'2026-12-01',v_staff.primary_role,v_staff.secondary_roles,
    v_staff.employment_type,'__cost_test_commission_to_31_oct',v_staff.fte,v_staff.primary_location_id,'archive rejection test',v_old);
  EXCEPTION WHEN check_violation THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'A newly dated archived-plan assignment was allowed'; END IF;
  v_denied:=false;
  BEGIN
    INSERT INTO public.theoretical_commission_benchmarks(plan_id,effective_start_date,effective_end_date)
      VALUES(v_old,'2026-10-01','2026-10-15');
    SET CONSTRAINTS theoretical_benchmark_no_overlap IMMEDIATE;
  EXCEPTION WHEN exclusion_violation THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Overlapping theoretical benchmarks were allowed'; END IF;
  PERFORM public.undo_latest_staff_role_assignment(v_staff.id,(v_result->>'assignment_id')::uuid,'undo stable plan test');
  IF (SELECT remuneration_plan_id FROM public.staff_members WHERE id=v_staff.id) IS DISTINCT FROM v_old THEN
    RAISE EXCEPTION 'Undo rebound to replacement name instead of original plan ID'; END IF;
  UPDATE public.staff_members SET notes=notes WHERE id=v_staff.id;
  UPDATE public.staff_role_assignments SET remuneration_plan_id=NULL,remuneration_plan=NULL
    WHERE staff_member_id=v_staff.id AND effective_end_date IS NULL;
  IF private.staff_plan_id_at(v_staff.id,'2026-11-01') IS NOT NULL OR
    private.staff_plan_id_at(v_staff.id,v_original_date) IS DISTINCT FROM v_old THEN
    RAISE EXCEPTION 'Explicit unconfigured assignment was confused with a history gap'; END IF;
  v_denied:=false;
  BEGIN UPDATE public.remuneration_plans SET plan_name='__renamed_wage' WHERE lower(plan_name)='wage';
  EXCEPTION WHEN check_violation THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Legacy Wage classification rename guard is missing'; END IF;
  PERFORM set_config('request.jwt.claims',jsonb_build_object('sub',gen_random_uuid(),'role','authenticated')::text,true);
  v_denied:=false;
  BEGIN PERFORM public.admin_duplicate_remuneration_plan(v_old,'__unauthorized');
  EXCEPTION WHEN insufficient_privilege THEN v_denied:=true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'Unauthorized plan changes were allowed'; END IF;
  RAISE NOTICE 'PASS: stable IDs, frozen gap fallback, copied rates, dated benchmark, archive/edit/delete guards, safe undo and unauthorized plan rejection';
END;
$tests$;
SET CONSTRAINTS ALL IMMEDIATE;
SELECT 'PASS: stable plan identity, date boundaries and plan-management assertions; all fixtures roll back' AS result;
ROLLBACK;
