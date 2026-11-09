-- Exercise actual authenticated/anon database roles, not only caller JWT claims.
-- Matrix changes and all other fixture changes are transaction-local.
BEGIN;
CREATE TEMP TABLE cost_permission_test_caller AS
SELECT a.user_id FROM public.staff_member_user_access a WHERE a.is_active
  AND a.access_role NOT IN ('admin','superadmin') AND NOT EXISTS (
    SELECT 1 FROM public.staff_member_user_access x WHERE x.user_id=a.user_id AND x.is_active AND x.access_role IN ('admin','superadmin')
  ) LIMIT 1;
DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM cost_permission_test_caller) THEN RAISE EXCEPTION 'Need a copied non-admin caller for permission tests'; END IF; END $$;
UPDATE public.staff_member_user_access SET access_role='manager' WHERE user_id=(SELECT user_id FROM cost_permission_test_caller);
INSERT INTO public.role_page_permissions(page_id,role_key,access_level)
SELECT p,'manager','view' FROM unnest(ARRAY['service_product_costs','remuneration','staff']) p
ON CONFLICT(page_id,role_key) DO UPDATE SET access_level='view';
SELECT set_config('request.jwt.claims',jsonb_build_object('sub',user_id,'role','authenticated')::text,true) FROM cost_permission_test_caller;
SET LOCAL ROLE authenticated;
DO $view_permissions$
DECLARE blocked boolean; affected bigint;
BEGIN
  PERFORM public.get_service_product_costs();
  PERFORM public.admin_list_theoretical_benchmarks();
  blocked:=false;
  BEGIN PERFORM public.create_service_product_cost_service('__permission_test');
  EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'View-only caller created a service'; END IF;
  blocked:=false;
  BEGIN PERFORM public.save_service_product_costs('[]'::jsonb);
  EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'View-only caller accessed cost writes'; END IF;
  blocked:=false;
  BEGIN PERFORM public.admin_duplicate_remuneration_plan((SELECT id FROM public.remuneration_plans LIMIT 1),'__permission_test');
  EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'View-only caller duplicated a plan'; END IF;
  blocked:=false;
  BEGIN PERFORM public.apply_staff_role_assignment(gen_random_uuid(),'2026-11-01',NULL,NULL,NULL,NULL,NULL,NULL);
  EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'View-only staff caller accessed history writes'; END IF;
  UPDATE public.staff_members SET primary_role=primary_role||'__permission_test';
  GET DIAGNOSTICS affected=ROW_COUNT;
  IF affected<>0 THEN RAISE EXCEPTION 'View-only caller bypassed Staff profile write restrictions'; END IF;
  UPDATE public.staff_role_assignments SET remuneration_plan_id=NULL;
  GET DIAGNOSTICS affected=ROW_COUNT;
  IF affected<>0 THEN RAISE EXCEPTION 'View-only caller bypassed dated plan-ID write restrictions'; END IF;
  blocked:=false;
  BEGIN INSERT INTO public.staff_members(full_name) VALUES('__permission_test');
  EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'View-only caller inserted a Staff profile directly'; END IF;
  blocked:=false;
  BEGIN INSERT INTO public.staff_role_assignments(staff_member_id,effective_start_date)
    VALUES((SELECT id FROM public.staff_members LIMIT 1),'2040-01-01');
  EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'View-only caller inserted a dated plan assignment directly'; END IF;
  blocked:=false;
  BEGIN PERFORM public.delete_staff_member_admin((SELECT id FROM public.staff_members LIMIT 1));
  EXCEPTION WHEN no_data_found OR insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'View-only caller accessed the alternate Staff delete RPC'; END IF;
  UPDATE public.remuneration_plans SET conditions_text='__permission_test';
  GET DIAGNOSTICS affected=ROW_COUNT;
  IF affected<>0 THEN RAISE EXCEPTION 'View-only caller bypassed plan write RPC through table RLS'; END IF;
  blocked:=false;
  BEGIN INSERT INTO public.service_product_cost_services(service_name) VALUES('__permission_test');
  EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'View-only caller bypassed service write RPC through direct table INSERT'; END IF;
  IF has_function_privilege(current_user,'private.apply_staff_role_assignment_legacy(uuid,date,text,text,text,text,numeric,uuid,text)','EXECUTE') THEN
    RAISE EXCEPTION 'Legacy staff write function remains directly executable'; END IF;
  RAISE NOTICE 'PASS: view-only caller can read but cannot write costs/plans/staff history or bypass RLS';
END;
$view_permissions$;
RESET ROLE;
UPDATE public.role_page_permissions SET access_level='none' WHERE role_key='manager' AND page_id IN ('service_product_costs','remuneration','staff');
SET LOCAL ROLE authenticated;
DO $no_permissions$
DECLARE blocked boolean; rows bigint;
BEGIN
  blocked:=false;
  BEGIN PERFORM public.get_service_product_costs(); EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'Caller without service-cost access read the catalogue'; END IF;
  SELECT count(*) INTO rows FROM public.admin_list_theoretical_benchmarks();
  IF rows<>0 THEN RAISE EXCEPTION 'Caller without remuneration access read benchmarks'; END IF;
  SELECT count(*) INTO rows FROM public.remuneration_plans;
  IF rows<>0 THEN RAISE EXCEPTION 'Caller without staff/remuneration access read plan rows'; END IF;
  SELECT count(*) INTO rows FROM public.remuneration_plan_rates;
  IF rows<>0 THEN RAISE EXCEPTION 'Caller without remuneration access read plan rates'; END IF;
  SELECT count(*) INTO rows FROM public.staff_members;
  IF rows<>0 THEN RAISE EXCEPTION 'Caller without Staff page access read staff profiles directly'; END IF;
  SELECT count(*) INTO rows FROM public.staff_role_assignments;
  IF rows<>0 THEN RAISE EXCEPTION 'Caller without Staff page access read dated role/pay history directly'; END IF;
  blocked:=false;
  BEGIN PERFORM public.list_staff_role_assignments(gen_random_uuid()); EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'Caller without Staff access read role/pay history'; END IF;
  RAISE NOTICE 'PASS: callers with no page permission cannot read service costs, plans, rates, benchmarks or staff history';
END;
$no_permissions$;
RESET ROLE;
SELECT set_config('request.jwt.claims','{}',true);
SET LOCAL ROLE anon;
DO $anonymous$
DECLARE blocked boolean;
BEGIN
  blocked:=false;
  BEGIN PERFORM public.get_service_product_costs(); EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'Anonymous catalogue access was not rejected'; END IF;
  blocked:=false;
  BEGIN PERFORM public.admin_duplicate_remuneration_plan(NULL,'__anonymous'); EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'Anonymous plan write was not rejected'; END IF;
  blocked:=false;
  BEGIN PERFORM 1 FROM public.service_product_cost_versions; EXCEPTION WHEN insufficient_privilege THEN blocked:=true; END;
  IF NOT blocked THEN RAISE EXCEPTION 'Anonymous direct cost-table read was not rejected'; END IF;
  RAISE NOTICE 'PASS: anonymous catalogue/plan RPC and direct cost-table access rejected';
END;
$anonymous$;
RESET ROLE;
SELECT 'PASS: authenticated view/none and anonymous permission assertions; all fixtures roll back' AS result;
ROLLBACK;
