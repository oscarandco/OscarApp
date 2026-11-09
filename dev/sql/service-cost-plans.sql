-- Stable plan identities and safe, dated plan configuration.
-- Incorporated into the feature migration by the root agent. No cutover is
-- activated here: existing rates, staff assignments and deductions stay intact.

ALTER TABLE public.remuneration_plans
  ADD COLUMN deduct_service_product_costs boolean NOT NULL DEFAULT false;
ALTER TABLE public.staff_members
  ADD COLUMN remuneration_plan_id uuid REFERENCES public.remuneration_plans(id) ON DELETE RESTRICT,
  ADD COLUMN remuneration_plan_fallback_id uuid REFERENCES public.remuneration_plans(id) ON DELETE RESTRICT;
ALTER TABLE public.staff_role_assignments
  ADD COLUMN remuneration_plan_id uuid REFERENCES public.remuneration_plans(id) ON DELETE RESTRICT;

DO $validate$
BEGIN
  IF EXISTS (SELECT 1 FROM public.remuneration_plans GROUP BY lower(btrim(plan_name)) HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'Duplicate remuneration names must be reconciled before stable plan backfill';
  END IF;
  IF EXISTS (
    SELECT 1 FROM (
      SELECT remuneration_plan FROM public.staff_members
      UNION ALL SELECT remuneration_plan FROM public.staff_role_assignments
    ) s WHERE nullif(btrim(s.remuneration_plan),'') IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.remuneration_plans p WHERE lower(btrim(p.plan_name))=lower(btrim(s.remuneration_plan))
    )
  ) THEN RAISE EXCEPTION 'Unmatched staff/history remuneration plan names require review'; END IF;
END;
$validate$;

CREATE UNIQUE INDEX remuneration_plans_name_normalised_uidx ON public.remuneration_plans (lower(btrim(plan_name)));
UPDATE public.staff_members s SET remuneration_plan_id=p.id, remuneration_plan_fallback_id=p.id
FROM public.remuneration_plans p WHERE lower(btrim(p.plan_name))=lower(btrim(s.remuneration_plan));
UPDATE public.staff_role_assignments a SET remuneration_plan_id=p.id
FROM public.remuneration_plans p WHERE lower(btrim(p.plan_name))=lower(btrim(a.remuneration_plan));
CREATE INDEX staff_members_plan_id_idx ON public.staff_members(remuneration_plan_id);
CREATE INDEX staff_role_assignments_plan_id_idx ON public.staff_role_assignments(remuneration_plan_id);

DROP POLICY IF EXISTS remuneration_plans_elevated_all ON public.remuneration_plans;
DROP POLICY IF EXISTS remuneration_plan_rates_elevated_all ON public.remuneration_plan_rates;
CREATE POLICY remuneration_plan_read ON public.remuneration_plans FOR SELECT TO authenticated USING (
  (SELECT private.user_has_page_access('remuneration','view')) OR (SELECT private.user_has_page_access('staff','view')));
CREATE POLICY remuneration_plan_write ON public.remuneration_plans FOR ALL TO authenticated
  USING ((SELECT private.user_has_page_access('remuneration','full')))
  WITH CHECK ((SELECT private.user_has_page_access('remuneration','full')));
CREATE POLICY remuneration_rate_read ON public.remuneration_plan_rates FOR SELECT TO authenticated
  USING ((SELECT private.user_has_page_access('remuneration','view')));
CREATE POLICY remuneration_rate_write ON public.remuneration_plan_rates FOR ALL TO authenticated
  USING ((SELECT private.user_has_page_access('remuneration','full')))
  WITH CHECK ((SELECT private.user_has_page_access('remuneration','full')));

CREATE TABLE public.theoretical_commission_benchmarks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  plan_id uuid NOT NULL REFERENCES public.remuneration_plans(id) ON DELETE RESTRICT,
  effective_start_date date NOT NULL,
  effective_end_date date,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT theoretical_benchmark_dates_valid CHECK (effective_end_date IS NULL OR effective_end_date>=effective_start_date),
  CONSTRAINT theoretical_benchmark_no_overlap EXCLUDE USING gist (
    daterange(effective_start_date,coalesce(effective_end_date,'infinity'::date),'[]') WITH &&
  ) DEFERRABLE INITIALLY IMMEDIATE
);
ALTER TABLE public.theoretical_commission_benchmarks OWNER TO postgres;
ALTER TABLE public.theoretical_commission_benchmarks ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.theoretical_commission_benchmarks FROM anon, authenticated;
GRANT SELECT ON public.theoretical_commission_benchmarks TO authenticated;
CREATE POLICY theoretical_benchmark_elevated_read ON public.theoretical_commission_benchmarks FOR SELECT TO authenticated
  USING ((SELECT private.user_has_page_access('remuneration','view')));
INSERT INTO public.theoretical_commission_benchmarks(plan_id,effective_start_date)
SELECT id, '0001-01-01'::date FROM public.remuneration_plans WHERE lower(btrim(plan_name))='commission';
DO $validate$ BEGIN
  IF (SELECT count(*) FROM public.theoretical_commission_benchmarks)<>1 THEN
    RAISE EXCEPTION 'Exactly one original Commission plan is required to seed the historical benchmark';
  END IF;
END; $validate$;

CREATE OR REPLACE FUNCTION private.staff_plan_id_at(p_staff uuid,p_date date)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT CASE WHEN a.id IS NOT NULL THEN a.remuneration_plan_id ELSE s.remuneration_plan_fallback_id END
  FROM public.staff_members s LEFT JOIN LATERAL (
    SELECT h.id,h.remuneration_plan_id FROM public.staff_role_assignments h
    WHERE h.staff_member_id=p_staff AND h.effective_start_date<=p_date
    AND (h.effective_end_date IS NULL OR h.effective_end_date>=p_date)
    ORDER BY h.effective_start_date DESC LIMIT 1
  ) a ON true WHERE s.id=p_staff;
$fn$;
CREATE OR REPLACE FUNCTION private.benchmark_plan_id_at(p_date date)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT b.plan_id FROM public.theoretical_commission_benchmarks b WHERE b.effective_start_date<=p_date
    AND (b.effective_end_date IS NULL OR b.effective_end_date>=p_date);
$fn$;
REVOKE ALL ON FUNCTION private.staff_plan_id_at(uuid,date),private.benchmark_plan_id_at(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.staff_plan_id_at(uuid,date),private.benchmark_plan_id_at(date) TO authenticated,service_role;

CREATE OR REPLACE FUNCTION public.staff_profile_at(p_staff uuid,p_date date)
RETURNS SETOF public.staff_role_assignments LANGUAGE sql STABLE PARALLEL SAFE SET search_path=public,pg_temp AS $fn$
  SELECT a.* FROM public.staff_role_assignments a WHERE a.staff_member_id=p_staff
    AND a.effective_start_date<=p_date AND (a.effective_end_date IS NULL OR a.effective_end_date>=p_date)
  ORDER BY a.effective_start_date DESC LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION private.require_plan_admin()
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_page_access('remuneration','full')) THEN
    RAISE EXCEPTION 'Not authorized to manage remuneration plans' USING ERRCODE='42501';
  END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION private.require_plan_admin() FROM PUBLIC;

CREATE OR REPLACE FUNCTION private.require_staff_plan_access(p_write boolean DEFAULT true)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
BEGIN
  IF auth.uid() IS NULL OR NOT private.user_has_page_access('staff',CASE WHEN p_write THEN 'full' ELSE 'view' END) THEN
    RAISE EXCEPTION 'Not authorized to manage staff plan history' USING ERRCODE='42501';
  END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION private.require_staff_plan_access(boolean) FROM PUBLIC;

CREATE OR REPLACE FUNCTION private.plan_is_referenced(p_plan_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT EXISTS(SELECT 1 FROM public.staff_members WHERE remuneration_plan_id=p_plan_id OR remuneration_plan_fallback_id=p_plan_id)
    OR EXISTS(SELECT 1 FROM public.staff_role_assignments WHERE remuneration_plan_id=p_plan_id)
    OR EXISTS(SELECT 1 FROM public.theoretical_commission_benchmarks WHERE plan_id=p_plan_id);
$fn$;
REVOKE ALL ON FUNCTION private.plan_is_referenced(uuid) FROM PUBLIC;

CREATE OR REPLACE FUNCTION private.protect_used_plan_settings()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
DECLARE v_id uuid;
BEGIN
  IF TG_TABLE_NAME='remuneration_plans' THEN
    v_id:=OLD.id;
    IF TG_OP='UPDATE' AND lower(btrim(OLD.plan_name))='wage' AND lower(btrim(NEW.plan_name))<>'wage' THEN
      RAISE EXCEPTION 'The Wage plan name is used by legacy attribution rules and cannot be renamed.' USING ERRCODE='23514';
    END IF;
    IF private.plan_is_referenced(v_id) AND (TG_OP='DELETE' OR
      NEW.can_use_assistants IS DISTINCT FROM OLD.can_use_assistants OR
      NEW.deduct_service_product_costs IS DISTINCT FROM OLD.deduct_service_product_costs) THEN
      RAISE EXCEPTION 'This plan is referenced by staff/history or a benchmark. Duplicate it to change calculation settings.' USING ERRCODE='23514';
    END IF;
  ELSE
    v_id:=CASE WHEN TG_OP='INSERT' THEN NEW.remuneration_plan_id ELSE OLD.remuneration_plan_id END;
    IF (private.plan_is_referenced(v_id) OR (TG_OP='UPDATE' AND private.plan_is_referenced(NEW.remuneration_plan_id))) AND (TG_OP IN ('INSERT','DELETE') OR
      NEW.rate IS DISTINCT FROM OLD.rate OR NEW.commission_category IS DISTINCT FROM OLD.commission_category OR
      NEW.remuneration_plan_id IS DISTINCT FROM OLD.remuneration_plan_id) THEN
      RAISE EXCEPTION 'Rates on a referenced plan are protected. Duplicate the plan before changing rates.' USING ERRCODE='23514';
    END IF;
  END IF;
  IF TG_OP='DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$fn$;
REVOKE ALL ON FUNCTION private.protect_used_plan_settings() FROM PUBLIC;
CREATE TRIGGER protect_referenced_plan BEFORE UPDATE OR DELETE ON public.remuneration_plans
  FOR EACH ROW EXECUTE FUNCTION private.protect_used_plan_settings();
CREATE TRIGGER protect_referenced_plan_rates BEFORE INSERT OR UPDATE OR DELETE ON public.remuneration_plan_rates
  FOR EACH ROW EXECUTE FUNCTION private.protect_used_plan_settings();

-- Keep legacy display-name fields for compatibility, but an unchanged stable ID
-- always wins over stale text. This prevents name reuse rebinding old assignments.
CREATE OR REPLACE FUNCTION private.sync_staff_plan_identity()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
DECLARE v_id uuid; v_name text; v_active boolean; v_changed boolean;
BEGIN
  IF TG_TABLE_NAME='staff_members' THEN
    IF TG_OP='UPDATE' THEN
      IF NEW.remuneration_plan_fallback_id IS DISTINCT FROM OLD.remuneration_plan_fallback_id THEN
        RAISE EXCEPTION 'Historical fallback plan identity is immutable' USING ERRCODE='23514';
      END IF;
    END IF;
  END IF;
  v_id:=NEW.remuneration_plan_id;
  IF TG_OP='INSERT' THEN
    v_changed:=v_id IS NOT NULL OR nullif(btrim(NEW.remuneration_plan),'') IS NOT NULL;
    IF v_id IS NULL AND nullif(btrim(NEW.remuneration_plan),'') IS NOT NULL THEN
      SELECT id INTO v_id FROM public.remuneration_plans WHERE lower(btrim(plan_name))=lower(btrim(NEW.remuneration_plan));
    END IF;
  ELSE
    v_changed:=NEW.remuneration_plan_id IS DISTINCT FROM OLD.remuneration_plan_id;
    -- Text-only legacy calls can select a different name; unchanged legacy text
    -- never re-resolves an existing permanent ID after a rename/reuse.
    IF NOT v_changed AND NEW.remuneration_plan IS DISTINCT FROM OLD.remuneration_plan THEN
      IF nullif(btrim(NEW.remuneration_plan),'') IS NULL THEN v_id:=NULL;
      ELSE SELECT id INTO v_id FROM public.remuneration_plans WHERE lower(btrim(plan_name))=lower(btrim(NEW.remuneration_plan)); END IF;
      v_changed:=v_id IS DISTINCT FROM OLD.remuneration_plan_id;
    END IF;
  END IF;
  IF v_id IS NULL THEN
    IF nullif(btrim(NEW.remuneration_plan),'') IS NOT NULL AND (TG_OP='INSERT' OR v_changed) THEN
      RAISE EXCEPTION 'Unknown remuneration plan' USING ERRCODE='22023';
    END IF;
    NEW.remuneration_plan_id:=NULL;
    NEW.remuneration_plan:=NULL;
    RETURN NEW;
  END IF;
  SELECT plan_name,is_active INTO v_name,v_active FROM public.remuneration_plans WHERE id=v_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown remuneration plan ID' USING ERRCODE='22023'; END IF;
  IF v_changed AND NOT v_active AND NOT (TG_TABLE_NAME='staff_members' AND EXISTS(
    SELECT 1 FROM public.staff_role_assignments a WHERE a.staff_member_id=NEW.id AND a.effective_end_date IS NULL AND a.remuneration_plan_id=v_id
  )) THEN RAISE EXCEPTION 'Archived plans cannot be newly assigned' USING ERRCODE='23514'; END IF;
  NEW.remuneration_plan_id:=v_id; NEW.remuneration_plan:=v_name;
  IF TG_TABLE_NAME='staff_members' AND TG_OP='INSERT' THEN NEW.remuneration_plan_fallback_id:=v_id; END IF;
  RETURN NEW;
END;
$fn$;
REVOKE ALL ON FUNCTION private.sync_staff_plan_identity() FROM PUBLIC;
CREATE TRIGGER sync_staff_member_plan_identity BEFORE INSERT OR UPDATE ON public.staff_members
  FOR EACH ROW EXECUTE FUNCTION private.sync_staff_plan_identity();
CREATE TRIGGER sync_staff_assignment_plan_identity BEFORE INSERT OR UPDATE ON public.staff_role_assignments
  FOR EACH ROW EXECUTE FUNCTION private.sync_staff_plan_identity();

CREATE OR REPLACE FUNCTION public.admin_save_remuneration_plan(
  p_plan_id uuid,p_plan_name text,p_can_use_assistants boolean,p_conditions_text text,
  p_deduct_service_product_costs boolean,p_rates jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
DECLARE v_id uuid:=p_plan_id; v_category text; v_rate numeric;
BEGIN
  PERFORM private.require_plan_admin();
  IF nullif(btrim(p_plan_name),'') IS NULL THEN RAISE EXCEPTION 'Plan name is required' USING ERRCODE='22023'; END IF;
  IF jsonb_typeof(p_rates)<>'object' OR (SELECT count(*) FROM jsonb_object_keys(p_rates))<>6 THEN
    RAISE EXCEPTION 'Supply all six commission rates' USING ERRCODE='22023'; END IF;
  FOREACH v_category IN ARRAY ARRAY['retail_product','professional_product','service','toner_with_other_service','extensions_product','extensions_service'] LOOP
    IF NOT p_rates ? v_category OR jsonb_typeof(p_rates->v_category)<>'number' THEN
      RAISE EXCEPTION 'Missing or invalid rate for %',v_category USING ERRCODE='22023'; END IF;
    v_rate:=(p_rates->>v_category)::numeric;
    IF v_rate<0 OR v_rate>1 THEN RAISE EXCEPTION 'Rates must be between 0 and 1' USING ERRCODE='22023'; END IF;
  END LOOP;
  IF v_id IS NULL THEN
    INSERT INTO public.remuneration_plans(plan_name,can_use_assistants,conditions_text,deduct_service_product_costs)
    VALUES(btrim(p_plan_name),coalesce(p_can_use_assistants,false),nullif(btrim(p_conditions_text),''),coalesce(p_deduct_service_product_costs,false)) RETURNING id INTO v_id;
  ELSE
    PERFORM 1 FROM public.remuneration_plans WHERE id=v_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found' USING ERRCODE='P0002'; END IF;
    IF EXISTS(SELECT 1 FROM public.remuneration_plans WHERE id=v_id AND NOT is_active) THEN
      RAISE EXCEPTION 'Restore an archived plan before editing it' USING ERRCODE='23514'; END IF;
    UPDATE public.remuneration_plans SET plan_name=btrim(p_plan_name),can_use_assistants=coalesce(p_can_use_assistants,false),
      conditions_text=nullif(btrim(p_conditions_text),''),deduct_service_product_costs=coalesce(p_deduct_service_product_costs,false),updated_at=now() WHERE id=v_id;
  END IF;
  FOR v_category,v_rate IN SELECT key,value::text::numeric FROM jsonb_each(p_rates) LOOP
    UPDATE public.remuneration_plan_rates SET rate=v_rate,updated_at=now()
      WHERE remuneration_plan_id=v_id AND commission_category=v_category AND rate IS DISTINCT FROM v_rate;
    IF NOT EXISTS(SELECT 1 FROM public.remuneration_plan_rates WHERE remuneration_plan_id=v_id AND commission_category=v_category) THEN
      INSERT INTO public.remuneration_plan_rates(remuneration_plan_id,commission_category,rate) VALUES(v_id,v_category,v_rate);
    END IF;
  END LOOP;
  RETURN v_id;
END;
$fn$;

CREATE OR REPLACE FUNCTION public.admin_duplicate_remuneration_plan(p_plan_id uuid,p_plan_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
DECLARE v_plan public.remuneration_plans; v_rates jsonb;
BEGIN
  PERFORM private.require_plan_admin();
  SELECT * INTO STRICT v_plan FROM public.remuneration_plans WHERE id=p_plan_id FOR SHARE;
  SELECT jsonb_object_agg(commission_category,rate) INTO v_rates FROM public.remuneration_plan_rates WHERE remuneration_plan_id=p_plan_id;
  RETURN public.admin_save_remuneration_plan(NULL,p_plan_name,v_plan.can_use_assistants,v_plan.conditions_text,v_plan.deduct_service_product_costs,v_rates);
END;
$fn$;
CREATE OR REPLACE FUNCTION public.admin_set_remuneration_plan_active(p_plan_id uuid,p_is_active boolean)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
BEGIN
  PERFORM private.require_plan_admin();
  IF p_is_active IS NULL THEN RAISE EXCEPTION 'Status is required' USING ERRCODE='22023'; END IF;
  UPDATE public.remuneration_plans SET is_active=p_is_active,updated_at=now() WHERE id=p_plan_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Plan not found' USING ERRCODE='P0002'; END IF;
END;
$fn$;
CREATE OR REPLACE FUNCTION public.admin_delete_remuneration_plan_if_unused(p_plan_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
BEGIN
  PERFORM private.require_plan_admin();
  IF private.plan_is_referenced(p_plan_id) THEN RAISE EXCEPTION 'Plan is referenced by staff, history or a theoretical benchmark; archive it instead.' USING ERRCODE='23514'; END IF;
  DELETE FROM public.remuneration_plans WHERE id=p_plan_id;
END;
$fn$;
CREATE OR REPLACE FUNCTION public.admin_staff_for_remuneration_plan_id(p_plan_id uuid)
RETURNS TABLE(staff_member_id uuid,display_name text,full_name text,is_active boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT s.id,s.display_name,s.full_name,s.is_active FROM public.staff_members s
  WHERE (SELECT private.user_has_page_access('remuneration','view')) AND s.remuneration_plan_id=p_plan_id ORDER BY coalesce(s.display_name,s.full_name,'');
$fn$;
CREATE OR REPLACE FUNCTION public.admin_remuneration_staff_counts_by_id()
RETURNS TABLE(plan_id uuid,staff_count bigint) LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT s.remuneration_plan_id,count(*) FROM public.staff_members s WHERE (SELECT private.user_has_page_access('remuneration','view'))
    AND s.remuneration_plan_id IS NOT NULL GROUP BY s.remuneration_plan_id;
$fn$;
CREATE OR REPLACE FUNCTION public.admin_list_theoretical_benchmarks()
RETURNS TABLE(id uuid,plan_id uuid,plan_name text,effective_start_date date,effective_end_date date)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $fn$
  SELECT b.id,b.plan_id,p.plan_name,b.effective_start_date,b.effective_end_date
  FROM public.theoretical_commission_benchmarks b JOIN public.remuneration_plans p ON p.id=b.plan_id
  WHERE (SELECT private.user_has_page_access('remuneration','view')) ORDER BY b.effective_start_date DESC;
$fn$;
CREATE OR REPLACE FUNCTION public.admin_set_theoretical_benchmark(p_plan_id uuid,p_effective_start_date date)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
DECLARE v_current public.theoretical_commission_benchmarks;
BEGIN
  PERFORM private.require_plan_admin();
  IF p_effective_start_date IS NULL THEN RAISE EXCEPTION 'Effective date is required' USING ERRCODE='22023'; END IF;
  PERFORM 1 FROM public.remuneration_plans WHERE id=p_plan_id AND is_active FOR SHARE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Select an active plan' USING ERRCODE='22023'; END IF;
  LOCK TABLE public.theoretical_commission_benchmarks IN SHARE ROW EXCLUSIVE MODE;
  SELECT * INTO STRICT v_current FROM public.theoretical_commission_benchmarks WHERE effective_end_date IS NULL FOR UPDATE;
  IF p_effective_start_date=v_current.effective_start_date AND p_plan_id=v_current.plan_id THEN RETURN; END IF;
  IF p_effective_start_date<=v_current.effective_start_date THEN RAISE EXCEPTION 'Add a benchmark after the latest effective date; historical periods cannot be replaced' USING ERRCODE='23514'; END IF;
  SET CONSTRAINTS theoretical_benchmark_no_overlap DEFERRED;
  UPDATE public.theoretical_commission_benchmarks SET effective_end_date=p_effective_start_date-1 WHERE id=v_current.id;
  INSERT INTO public.theoretical_commission_benchmarks(plan_id,effective_start_date,created_by) VALUES(p_plan_id,p_effective_start_date,auth.uid());
END;
$fn$;

-- Hide the original nine-argument implementation behind a compatibility wrapper.
-- Its established date/history validation is preserved; the wrapper synchronises
-- permanent IDs after its atomic change, including same-name plan reuse.
ALTER FUNCTION public.apply_staff_role_assignment(uuid,date,text,text,text,text,numeric,uuid,text) SET SCHEMA private;
ALTER FUNCTION private.apply_staff_role_assignment(uuid,date,text,text,text,text,numeric,uuid,text) RENAME TO apply_staff_role_assignment_legacy;
REVOKE ALL ON FUNCTION private.apply_staff_role_assignment_legacy(uuid,date,text,text,text,text,numeric,uuid,text) FROM PUBLIC,authenticated,service_role;
DO $authorization$ BEGIN
  EXECUTE replace(pg_get_functiondef('private.apply_staff_role_assignment_legacy(uuid,date,text,text,text,text,numeric,uuid,text)'::regprocedure),
    'private.user_has_elevated_access()', 'private.user_has_page_access(''staff'',''full'')');
END; $authorization$;
CREATE FUNCTION public.apply_staff_role_assignment(
  p_staff_member_id uuid,p_effective_start_date date,p_primary_role text,p_secondary_roles text,p_employment_type text,
  p_remuneration_plan text,p_fte numeric,p_primary_location_id uuid,p_reason text DEFAULT NULL,p_remuneration_plan_id uuid DEFAULT NULL
) RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
DECLARE v_id uuid:=p_remuneration_plan_id; v_name text; v_result jsonb;
BEGIN
  PERFORM private.require_staff_plan_access();
  IF v_id IS NULL AND nullif(btrim(p_remuneration_plan),'') IS NOT NULL THEN
    SELECT id INTO v_id FROM public.remuneration_plans WHERE lower(btrim(plan_name))=lower(btrim(p_remuneration_plan));
    IF NOT FOUND THEN RAISE EXCEPTION 'Unknown remuneration plan' USING ERRCODE='22023'; END IF;
  END IF;
  IF v_id IS NOT NULL THEN
    SELECT plan_name INTO v_name FROM public.remuneration_plans WHERE id=v_id AND is_active FOR SHARE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Choose an active remuneration plan for a new dated assignment' USING ERRCODE='23514'; END IF;
  END IF;
  v_result:=private.apply_staff_role_assignment_legacy(p_staff_member_id,p_effective_start_date,p_primary_role,p_secondary_roles,
    p_employment_type,v_name,p_fte,p_primary_location_id,p_reason);
  UPDATE public.staff_role_assignments SET remuneration_plan_id=v_id,remuneration_plan=v_name
    WHERE id=(v_result->>'assignment_id')::uuid;
  IF (v_result->>'synced_staff_members')::boolean THEN
    UPDATE public.staff_members SET remuneration_plan_id=v_id,remuneration_plan=v_name WHERE id=p_staff_member_id;
  END IF;
  RETURN v_result;
END;
$fn$;

-- Undo's legacy text snapshot is resolved from the permanent history ID before
-- the existing implementation copies it back to staff_members. This avoids a
-- stale original name binding to the replacement plan during undo.
ALTER FUNCTION public.undo_latest_staff_role_assignment(uuid,uuid,text) SET SCHEMA private;
ALTER FUNCTION private.undo_latest_staff_role_assignment(uuid,uuid,text) RENAME TO undo_latest_staff_role_assignment_legacy;
REVOKE ALL ON FUNCTION private.undo_latest_staff_role_assignment_legacy(uuid,uuid,text) FROM PUBLIC,authenticated,service_role;
DO $authorization$ BEGIN
  EXECUTE replace(pg_get_functiondef('private.undo_latest_staff_role_assignment_legacy(uuid,uuid,text)'::regprocedure),
    'private.user_has_elevated_access()', 'private.user_has_page_access(''staff'',''full'')');
END; $authorization$;
CREATE FUNCTION public.undo_latest_staff_role_assignment(p_staff_member_id uuid,p_assignment_id uuid,p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
DECLARE v_result jsonb; v_id uuid; v_name text;
BEGIN
  PERFORM private.require_staff_plan_access();
  -- Synchronise compatibility labels from IDs without changing identities.
  UPDATE public.staff_role_assignments a SET remuneration_plan=p.plan_name
    FROM public.remuneration_plans p WHERE a.staff_member_id=p_staff_member_id AND a.remuneration_plan_id=p.id
      AND a.remuneration_plan IS DISTINCT FROM p.plan_name;
  v_result:=private.undo_latest_staff_role_assignment_legacy(p_staff_member_id,p_assignment_id,p_reason);
  SELECT a.remuneration_plan_id,p.plan_name INTO v_id,v_name FROM public.staff_role_assignments a
    LEFT JOIN public.remuneration_plans p ON p.id=a.remuneration_plan_id WHERE a.id=(v_result->>'reopened_assignment_id')::uuid;
  UPDATE public.staff_members SET remuneration_plan_id=v_id,remuneration_plan=v_name WHERE id=p_staff_member_id;
  RETURN v_result;
END;
$fn$;

DROP FUNCTION public.list_staff_role_assignments(uuid);
CREATE FUNCTION public.list_staff_role_assignments(p_staff_member_id uuid)
RETURNS TABLE(id uuid,staff_member_id uuid,effective_start_date date,effective_end_date date,primary_role text,secondary_roles text,
  employment_type text,remuneration_plan text,fte numeric,primary_location_id uuid,primary_location_name text,reason text,
  created_at timestamptz,created_by uuid,updated_at timestamptz,updated_by uuid,remuneration_plan_id uuid)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,private,pg_temp AS $fn$
BEGIN
  PERFORM private.require_staff_plan_access(false);
  RETURN QUERY SELECT a.id,a.staff_member_id,a.effective_start_date,a.effective_end_date,a.primary_role,a.secondary_roles,
    a.employment_type,p.plan_name,a.fte,a.primary_location_id,l.name,a.reason,a.created_at,a.created_by,a.updated_at,a.updated_by,a.remuneration_plan_id
    FROM public.staff_role_assignments a LEFT JOIN public.locations l ON l.id=a.primary_location_id
    LEFT JOIN public.remuneration_plans p ON p.id=a.remuneration_plan_id WHERE a.staff_member_id=p_staff_member_id
    ORDER BY a.effective_start_date DESC,a.created_at DESC;
END;
$fn$;

DO $permissions$
DECLARE r record;
BEGIN
  FOR r IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='private' AND p.proname IN ('staff_plan_id_at','benchmark_plan_id_at','require_plan_admin',
      'require_staff_plan_access','plan_is_referenced','protect_used_plan_settings','sync_staff_plan_identity')
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO postgres',r.signature);
  END LOOP;
  FOR r IN SELECT p.oid::regprocedure AS signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
    WHERE n.nspname='public' AND p.proname IN ('admin_save_remuneration_plan','admin_duplicate_remuneration_plan',
      'admin_set_remuneration_plan_active','admin_delete_remuneration_plan_if_unused','admin_staff_for_remuneration_plan_id',
      'admin_remuneration_staff_counts_by_id','admin_list_theoretical_benchmarks','admin_set_theoretical_benchmark',
      'apply_staff_role_assignment','undo_latest_staff_role_assignment','list_staff_role_assignments')
  LOOP
    EXECUTE format('ALTER FUNCTION %s OWNER TO postgres',r.signature);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon',r.signature);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated,service_role',r.signature);
  END LOOP;
END;
$permissions$;
