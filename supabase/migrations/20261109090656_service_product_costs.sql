-- Additive service product costs feature. Source definitions reconciled against c6748c7.
BEGIN;
SET LOCAL search_path=public,extensions,private,pg_temp;


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


-- Stable plan IDs are not protected if an elevated caller with Staff view can
-- bypass the dated RPC through the old generic elevated table policies.
-- Replace every existing policy on these two tables, keeping authenticated
-- SELECT at Staff view and INSERT/UPDATE at Staff full. No DELETE policy is added.
DO $policies$
DECLARE r record;
BEGIN
  FOR r IN SELECT schemaname,tablename,policyname FROM pg_policies
    WHERE schemaname='public' AND tablename IN ('staff_members','staff_role_assignments')
  LOOP EXECUTE format('DROP POLICY %I ON %I.%I',r.policyname,r.schemaname,r.tablename); END LOOP;
END;
$policies$;
CREATE POLICY staff_members_page_select ON public.staff_members FOR SELECT TO authenticated
  USING ((SELECT private.user_has_page_access('staff','view')));
CREATE POLICY staff_members_page_insert ON public.staff_members FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.user_has_page_access('staff','full')));
CREATE POLICY staff_members_page_update ON public.staff_members FOR UPDATE TO authenticated
  USING ((SELECT private.user_has_page_access('staff','full')))
  WITH CHECK ((SELECT private.user_has_page_access('staff','full')));
CREATE POLICY staff_role_assignments_page_select ON public.staff_role_assignments FOR SELECT TO authenticated
  USING ((SELECT private.user_has_page_access('staff','view')));
CREATE POLICY staff_role_assignments_page_insert ON public.staff_role_assignments FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.user_has_page_access('staff','full')));
CREATE POLICY staff_role_assignments_page_update ON public.staff_role_assignments FOR UPDATE TO authenticated
  USING ((SELECT private.user_has_page_access('staff','full')))
  WITH CHECK ((SELECT private.user_has_page_access('staff','full')));

-- Keep the established delete workflow and non-disclosing errors, while closing
-- the other Staff mutation RPC's old elevated-role-only authorization path.
DO $delete_permission$
BEGIN
  EXECUTE replace(pg_get_functiondef('public.delete_staff_member_admin(uuid)'::regprocedure),
    'private.user_has_elevated_access()', 'private.user_has_page_access(''staff'',''full'')');
END;
$delete_permission$;


-- Service costs use inclusive date intervals and decimal ex-GST unit amounts.
ALTER TABLE public.role_page_permissions DROP CONSTRAINT role_page_permissions_page_id_check;
ALTER TABLE public.role_page_permissions ADD CONSTRAINT role_page_permissions_page_id_check CHECK
 (page_id IN ('my_payroll','guest_quote','previous_quotes','kpi_dashboard','weekly_payroll','commission_breakdown','staff_trends','imports','staff','products','quotes','remuneration','access','role_permissions','contractor_invoices','business_settings','commission_guide','service_product_costs'));
INSERT INTO public.role_page_permissions(page_id,role_key,access_level)
 SELECT 'service_product_costs',k,CASE WHEN k='admin' THEN 'full' WHEN k='manager' THEN 'view' ELSE 'none' END
 FROM unnest(ARRAY['admin','manager','assistant','stylist','reception','assistant_uat','stylist_uat','reception_uat','manager_uat']) k ON CONFLICT DO NOTHING;

CREATE TABLE public.service_product_cost_services (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(), service_name text NOT NULL CHECK(btrim(service_name)<>''),
 is_active boolean NOT NULL DEFAULT true, created_at timestamptz NOT NULL DEFAULT now(),created_by uuid DEFAULT auth.uid());
CREATE TABLE public.service_product_cost_aliases (
 description_key text PRIMARY KEY, service_id uuid NOT NULL REFERENCES public.service_product_cost_services(id) ON DELETE RESTRICT);
CREATE INDEX ON public.service_product_cost_aliases(service_id);
CREATE TABLE public.service_product_source_mappings (
 location_id uuid NOT NULL REFERENCES public.locations(id), source_product_id text NOT NULL,
 service_id uuid NOT NULL REFERENCES public.service_product_cost_services(id) ON DELETE RESTRICT,
 PRIMARY KEY(location_id,source_product_id));
CREATE INDEX ON public.service_product_source_mappings(service_id);
CREATE TABLE public.service_product_cost_versions (
 id uuid PRIMARY KEY DEFAULT gen_random_uuid(),service_id uuid NOT NULL REFERENCES public.service_product_cost_services(id) ON DELETE RESTRICT,
 unit_cost_ex_gst numeric(12,4) NOT NULL CHECK(unit_cost_ex_gst>=0),effective_from date NOT NULL,effective_to date,
 created_at timestamptz NOT NULL DEFAULT now(),created_by uuid DEFAULT auth.uid(),
 CHECK(effective_to IS NULL OR effective_to>=effective_from),
 EXCLUDE USING gist (service_id WITH =,daterange(effective_from,effective_to,'[]') WITH &&));
CREATE INDEX ON public.service_product_cost_versions(service_id,effective_from DESC);
ALTER TABLE public.service_product_cost_services ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_product_cost_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_product_source_mappings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.service_product_cost_versions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.service_product_cost_services,public.service_product_cost_aliases,public.service_product_source_mappings,public.service_product_cost_versions FROM anon,authenticated;

CREATE FUNCTION private.require_service_cost_access(p_write boolean DEFAULT false) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT private.user_has_page_access('service_product_costs',CASE WHEN p_write THEN 'full' ELSE 'view' END) THEN
 RAISE EXCEPTION 'Service product costs access denied' USING ERRCODE='42501'; END IF;
END $$;

CREATE FUNCTION private.service_id_for_sale(p_raw uuid,p_location uuid,p_name text) RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
 SELECT coalesce((SELECT m.service_id FROM public.raw_sales_import_rows r JOIN public.service_product_source_mappings m
 ON m.location_id=p_location AND m.source_product_id=r.prod_id::text WHERE r.id=p_raw),
 (SELECT a.service_id FROM public.service_product_cost_aliases a WHERE a.description_key=lower(btrim(p_name))))
$$;

CREATE FUNCTION private.discover_service_product_costs() RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r record; sid uuid;
BEGIN
 PERFORM pg_advisory_xact_lock(683421);
 FOR r IN SELECT st.location_id,rawr.prod_id::text AS prod_id,st.product_service_name AS name,max(st.sale_date) last_date
 FROM public.sales_transactions st LEFT JOIN public.raw_sales_import_rows rawr ON rawr.id=st.raw_row_id
 JOIN public.v_sales_transactions_powerbi_parity p ON p.id=st.id
 WHERE p.product_type_actual_derived='Service' AND nullif(btrim(st.product_service_name),'') IS NOT NULL
 GROUP BY st.location_id,rawr.prod_id::text,st.product_service_name
 ORDER BY max(st.sale_date) DESC,st.product_service_name,st.location_id,rawr.prod_id::text LOOP
 sid:=NULL;
 SELECT m.service_id INTO sid FROM public.service_product_source_mappings m WHERE m.location_id=r.location_id AND m.source_product_id=r.prod_id;
 IF sid IS NULL THEN SELECT a.service_id INTO sid FROM public.service_product_cost_aliases a WHERE a.description_key=lower(btrim(r.name)); END IF;
 IF sid IS NULL THEN INSERT INTO public.service_product_cost_services(service_name,is_active) VALUES(btrim(r.name),r.last_date>=DATE '2026-11-01') RETURNING id INTO sid; END IF;
 INSERT INTO public.service_product_cost_aliases VALUES(lower(btrim(r.name)),sid) ON CONFLICT DO NOTHING;
 IF r.prod_id IS NOT NULL AND r.location_id IS NOT NULL THEN
 INSERT INTO public.service_product_source_mappings VALUES(r.location_id,r.prod_id,sid) ON CONFLICT DO NOTHING; END IF;
 END LOOP;
END $$;

CREATE FUNCTION private.discover_service_after_import() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN PERFORM private.discover_service_product_costs(); RETURN NULL; END $$;
CREATE TRIGGER discover_service_costs_after_import AFTER INSERT OR UPDATE OF product_service_name,raw_row_id,location_id ON public.sales_transactions
 FOR EACH STATEMENT EXECUTE FUNCTION private.discover_service_after_import();
SELECT private.discover_service_product_costs();

CREATE FUNCTION public.create_service_product_cost_service(p_service_name text) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE sid uuid;
BEGIN
 PERFORM private.require_service_cost_access(true); PERFORM pg_advisory_xact_lock(683421);
 IF nullif(btrim(p_service_name),'') IS NULL THEN RAISE EXCEPTION 'A service name is required'; END IF;
 IF EXISTS(SELECT 1 FROM public.service_product_cost_aliases WHERE description_key=lower(btrim(p_service_name))) THEN RAISE EXCEPTION 'This service already exists'; END IF;
 INSERT INTO public.service_product_cost_services(service_name) VALUES(btrim(p_service_name)) RETURNING id INTO sid;
 INSERT INTO public.service_product_cost_aliases VALUES(lower(btrim(p_service_name)),sid); RETURN sid;
END $$;

CREATE FUNCTION public.get_service_product_costs(p_as_of date DEFAULT current_date)
 RETURNS TABLE(service_id uuid,service_name text,is_active boolean,unit_cost_ex_gst numeric,effective_from date,effective_to date,seen_in_sales boolean,last_sale_date date,first_sale_date date,source_product_ids text[],location_names text[],classification_labels text[])
 LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN
 PERFORM private.require_service_cost_access(); PERFORM private.discover_service_product_costs();
 RETURN QUERY WITH usage AS (
 SELECT private.service_id_for_sale(st.raw_row_id,st.location_id,st.product_service_name) sid,min(st.sale_date) first_date,max(st.sale_date) last_date,array_agg(DISTINCT l.name) locs,array_agg(DISTINCT p.product_type_actual_derived) labels
 FROM public.sales_transactions st LEFT JOIN public.locations l ON l.id=st.location_id JOIN public.v_sales_transactions_powerbi_parity p ON p.id=st.id GROUP BY 1)
 SELECT s.id,s.service_name,s.is_active,c.unit_cost_ex_gst,c.effective_from,c.effective_to,u.sid IS NOT NULL,u.last_date,u.first_date,
 ARRAY(SELECT m.source_product_id FROM public.service_product_source_mappings m WHERE m.service_id=s.id ORDER BY m.source_product_id),u.locs,u.labels
 FROM public.service_product_cost_services s LEFT JOIN public.service_product_cost_versions c ON c.service_id=s.id AND p_as_of>=c.effective_from AND (c.effective_to IS NULL OR p_as_of<=c.effective_to)
 LEFT JOIN usage u ON u.sid=s.id ORDER BY s.service_name;
END $$;

CREATE FUNCTION public.get_service_product_cost_history(p_service_id uuid) RETURNS SETOF public.service_product_cost_versions LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN PERFORM private.require_service_cost_access(); RETURN QUERY SELECT * FROM public.service_product_cost_versions WHERE service_id=p_service_id ORDER BY effective_from DESC; END $$;

CREATE FUNCTION public.set_service_product_cost_service_active(p_service_id uuid,p_is_active boolean) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
BEGIN PERFORM private.require_service_cost_access(true); UPDATE public.service_product_cost_services SET is_active=p_is_active WHERE id=p_service_id; IF NOT FOUND THEN RAISE EXCEPTION 'Unknown service'; END IF; END $$;

CREATE FUNCTION public.save_service_product_costs(p_costs jsonb) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE r record; old public.service_product_cost_versions; next_date date;
BEGIN
 PERFORM private.require_service_cost_access(true); PERFORM pg_advisory_xact_lock(683421);
 IF p_costs IS NULL OR jsonb_typeof(p_costs)<>'array' OR jsonb_array_length(p_costs)=0 THEN RAISE EXCEPTION 'Enter at least one cost'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_to_recordset(p_costs) AS x(service_id uuid,effective_from date) GROUP BY service_id,effective_from HAVING count(*)>1) THEN RAISE EXCEPTION 'Duplicate service/date in cost batch'; END IF;
 FOR r IN SELECT * FROM jsonb_to_recordset(p_costs) AS x(service_id uuid,unit_cost_ex_gst numeric,effective_from date) ORDER BY service_id,effective_from LOOP
 IF r.service_id IS NULL OR r.effective_from IS NULL OR r.unit_cost_ex_gst IS NULL OR r.unit_cost_ex_gst<0 OR r.unit_cost_ex_gst>=100000000 THEN RAISE EXCEPTION 'Enter a service, effective date and non-negative cost'; END IF;
 PERFORM 1 FROM public.service_product_cost_services WHERE id=r.service_id AND is_active FOR UPDATE;
 IF NOT FOUND THEN RAISE EXCEPTION 'Unknown or archived service'; END IF;
 SELECT * INTO old FROM public.service_product_cost_versions WHERE service_id=r.service_id AND effective_from=r.effective_from;
 IF FOUND THEN
 IF old.unit_cost_ex_gst=r.unit_cost_ex_gst THEN CONTINUE; END IF;
 RAISE EXCEPTION 'A cost already starts on this date. Add a later version; existing history cannot be overwritten.'; END IF;
 SELECT min(effective_from) INTO next_date FROM public.service_product_cost_versions WHERE service_id=r.service_id AND effective_from>r.effective_from;
 UPDATE public.service_product_cost_versions SET effective_to=r.effective_from-1 WHERE service_id=r.service_id AND effective_from<r.effective_from AND (effective_to IS NULL OR effective_to>=r.effective_from);
 INSERT INTO public.service_product_cost_versions(service_id,unit_cost_ex_gst,effective_from,effective_to)
 VALUES(r.service_id,r.unit_cost_ex_gst,r.effective_from,next_date-1);
 END LOOP;
END $$;

-- Non-throwing basis metadata allows readiness to be queried before money fields.
CREATE FUNCTION private.service_commission_basis(p_sid uuid,p_date date,p_amount numeric,p_quantity numeric,p_actual boolean,p_theoretical boolean,p_eligible boolean,p_benchmark_found boolean)
 RETURNS TABLE(actual_product_cost_ex_gst numeric,actual_commissionable_ex_gst numeric,theoretical_product_cost_ex_gst numeric,theoretical_commissionable_ex_gst numeric,service_cost_status text)
 LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=public,pg_temp AS $$
DECLARE cost numeric;
BEGIN
 actual_product_cost_ex_gst:=0; theoretical_product_cost_ex_gst:=0;actual_commissionable_ex_gst:=p_amount; theoretical_commissionable_ex_gst:=p_amount;service_cost_status:='not_required';
 IF NOT p_eligible THEN RETURN NEXT; RETURN; END IF;
 IF NOT p_benchmark_found THEN service_cost_status:='missing_benchmark';
 ELSIF NOT (p_actual OR p_theoretical) THEN RETURN NEXT; RETURN;
 ELSIF p_quantity IS NULL OR p_quantity=0 OR p_amount IS NULL OR (p_amount<>0 AND sign(p_amount)<>sign(p_quantity)) THEN service_cost_status:='invalid_quantity';
 ELSIF p_sid IS NULL THEN service_cost_status:='missing_service';
 ELSE SELECT c.unit_cost_ex_gst INTO cost FROM public.service_product_cost_versions c WHERE c.service_id=p_sid AND p_date>=c.effective_from AND (c.effective_to IS NULL OR p_date<=c.effective_to);
 IF cost IS NULL THEN service_cost_status:='missing_cost'; ELSE service_cost_status:='ready'; END IF;
 END IF;
 IF service_cost_status NOT IN ('ready','not_required') THEN
 actual_product_cost_ex_gst:=NULL;theoretical_product_cost_ex_gst:=NULL;actual_commissionable_ex_gst:=NULL;theoretical_commissionable_ex_gst:=NULL;
 ELSE
 IF p_actual THEN actual_product_cost_ex_gst:=p_quantity*cost;actual_commissionable_ex_gst:=sign(p_amount)*greatest(abs(p_amount)-abs(p_quantity)*cost,0); END IF;
 IF p_theoretical THEN theoretical_product_cost_ex_gst:=p_quantity*cost;theoretical_commissionable_ex_gst:=sign(p_amount)*greatest(abs(p_amount)-abs(p_quantity)*cost,0); END IF;
 END IF;
 RETURN NEXT;
END $$;

CREATE FUNCTION private.require_ready_commission(p_amount numeric,p_status text) RETURNS numeric LANGUAGE plpgsql STABLE SET search_path=public,pg_temp AS $$
BEGIN IF p_status NOT IN ('ready','not_required') THEN RAISE EXCEPTION 'Commission awaiting product costs. Resolve the outstanding setup in Weekly payroll before reviewing this period. (%)',p_status USING ERRCODE='P0001'; END IF; RETURN p_amount; END $$;

-- Direct object writes are only available through authorised, atomic RPCs.
DO $$ DECLARE f regprocedure; BEGIN
 FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public'
 AND p.proname IN ('create_service_product_cost_service','get_service_product_costs','get_service_product_cost_history','set_service_product_cost_service_active','save_service_product_costs') LOOP
 EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon',f); EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',f); END LOOP;
END $$;


CREATE OR REPLACE FUNCTION public.update_role_page_permission(p_page_id text, p_role_key text, p_access_level text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_norm_page text;
  v_norm_role text;
  v_norm_level text;
  v_row public.role_page_permissions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT (SELECT private.user_can_manage_access_mappings()) THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  v_norm_page  := lower(trim(COALESCE(p_page_id, '')));
  v_norm_role  := lower(trim(COALESCE(p_role_key, '')));
  v_norm_level := lower(trim(COALESCE(p_access_level, '')));

  IF v_norm_page = '' OR v_norm_role = '' OR v_norm_level = '' THEN
    RAISE EXCEPTION 'page_id, role_key, and access_level are required';
  END IF;

  IF v_norm_role NOT IN (
    'assistant','stylist','reception','manager',
    'assistant_uat','stylist_uat','reception_uat','manager_uat','admin'
  ) THEN
    RAISE EXCEPTION 'Invalid role_key';
  END IF;

  IF v_norm_level NOT IN ('none', 'view', 'full') THEN
    RAISE EXCEPTION 'Invalid access_level';
  END IF;

  IF v_norm_page NOT IN (
    'service_product_costs','my_payroll','guest_quote','previous_quotes','kpi_dashboard',
    'weekly_payroll','commission_breakdown','staff_trends','imports','staff','products',
    'quotes','remuneration','access','role_permissions','contractor_invoices',
    'business_settings','commission_guide'
  ) THEN
    RAISE EXCEPTION 'Invalid page_id';
  END IF;

  -- Lockout guards (unchanged).
  IF v_norm_page = 'role_permissions' AND v_norm_role = 'admin' AND v_norm_level <> 'full' THEN
    RAISE EXCEPTION 'Admin must retain Full access to Role permissions';
  END IF;

  IF v_norm_page = 'access' AND v_norm_role = 'admin' AND v_norm_level = 'none' THEN
    RAISE EXCEPTION 'Admin must retain at least View access to Access';
  END IF;

  INSERT INTO public.role_page_permissions (page_id, role_key, access_level)
  VALUES (v_norm_page, v_norm_role, v_norm_level)
  ON CONFLICT (page_id, role_key)
  DO UPDATE SET access_level = EXCLUDED.access_level, updated_at = now()
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$function$;

CREATE OR REPLACE VIEW public.v_sales_transactions_powerbi_parity AS WITH base AS (
         SELECT st.id,
            st.import_batch_id,
            st.raw_row_id,
            st.location_id,
            st.invoice,
            st.customer_name,
            st.sale_datetime,
            st.sale_date,
            st.day_name,
            st.month_start,
            st.month_num,
            st.product_service_name,
            st.product_master_id,
            st.raw_product_type,
            st.product_type_actual AS existing_product_type_actual,
            st.product_type_short AS existing_product_type_short,
            st.commission_product_service AS existing_commission_product_service,
            st.quantity,
            st.price_ex_gst,
            st.price_incl_gst,
            st.price_gst_component,
            st.staff_commission_name,
            st.staff_work_name,
            st.staff_paid_name AS existing_staff_paid_name,
            st.staff_commission_id,
            st.staff_work_id,
            st.staff_paid_id,
            st.staff_commission_type,
            st.staff_work_type,
            st.staff_paid_type,
            st.assistant_usage_alert AS existing_assistant_usage_alert,
            st.staff_work_is_staff_paid,
            st.invoice_header,
            st.product_header,
            st.created_at,
            st.updated_at,
            pm.product_description AS master_product_description,
            pm.product_type AS master_product_type,
            COALESCE(sc.display_name, NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text)) AS commission_display_name,
            COALESCE(sc.full_name, NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text)) AS commission_full_name,
            COALESCE(sc_eff.primary_role, sc.primary_role) AS commission_primary_role,
            (SELECT plan_name FROM public.remuneration_plans WHERE id=private.staff_plan_id_at(COALESCE(st.staff_commission_id,sc.id),st.sale_date)) AS commission_remuneration_plan,
            COALESCE(sc_eff.employment_type, sc.employment_type) AS commission_employment_type,
            COALESCE(sw.display_name, NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text)) AS work_display_name,
            COALESCE(sw.full_name, NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text)) AS work_full_name,
            COALESCE(sw_eff.primary_role, sw.primary_role) AS work_primary_role,
            (SELECT plan_name FROM public.remuneration_plans WHERE id=private.staff_plan_id_at(COALESCE(st.staff_work_id,sw.id),st.sale_date)) AS work_remuneration_plan,
            COALESCE(sw_eff.employment_type, sw.employment_type) AS work_employment_type,
            rp.plan_name AS commission_plan_name,
            rp.can_use_assistants AS commission_can_use_assistants
           FROM sales_transactions st
             LEFT JOIN product_master pm ON lower(TRIM(BOTH FROM st.product_service_name)) = lower(TRIM(BOTH FROM pm.product_description))
             LEFT JOIN LATERAL ( SELECT sm.id,
                    sm.full_name,
                    sm.display_name,
                    sm.primary_role,
                    sm.remuneration_plan,
                    sm.employment_type,
                    sm.is_active,
                    sm.first_seen_sale_date,
                    sm.last_seen_sale_date,
                    sm.notes,
                    sm.created_at,
                    sm.updated_at,
                    sm.secondary_roles,
                    sm.fte,
                    sm.employment_start_date,
                    sm.employment_end_date,
                    sm.contractor_company_name,
                    sm.contractor_gst_registered,
                    sm.contractor_ird_number,
                    sm.contractor_street_address,
                    sm.contractor_suburb,
                    sm.contractor_city_postcode,
                    sm.primary_location_id,
                    sm.contractor_email,
                    sm.contractor_invoice_name,
                    sm.contractor_invoice_code
                   FROM staff_members sm
                  WHERE st.staff_commission_id IS NOT NULL AND sm.id = st.staff_commission_id OR st.staff_commission_id IS NULL AND NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text) IS NOT NULL AND lower(TRIM(BOTH FROM st.staff_commission_name)) = lower(TRIM(BOTH FROM sm.display_name)) AND sm.is_active = true
                  ORDER BY (
                        CASE
                            WHEN st.staff_commission_id IS NOT NULL AND sm.id = st.staff_commission_id THEN 0
                            ELSE 1
                        END)
                 LIMIT 1) sc ON true
             LEFT JOIN LATERAL ( SELECT sm.id,
                    sm.full_name,
                    sm.display_name,
                    sm.primary_role,
                    sm.remuneration_plan,
                    sm.employment_type,
                    sm.is_active,
                    sm.first_seen_sale_date,
                    sm.last_seen_sale_date,
                    sm.notes,
                    sm.created_at,
                    sm.updated_at,
                    sm.secondary_roles,
                    sm.fte,
                    sm.employment_start_date,
                    sm.employment_end_date,
                    sm.contractor_company_name,
                    sm.contractor_gst_registered,
                    sm.contractor_ird_number,
                    sm.contractor_street_address,
                    sm.contractor_suburb,
                    sm.contractor_city_postcode,
                    sm.primary_location_id,
                    sm.contractor_email,
                    sm.contractor_invoice_name,
                    sm.contractor_invoice_code
                   FROM staff_members sm
                  WHERE st.staff_work_id IS NOT NULL AND sm.id = st.staff_work_id OR st.staff_work_id IS NULL AND NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, ''::text)), ''::text) IS NOT NULL AND lower(TRIM(BOTH FROM st.staff_work_name)) = lower(TRIM(BOTH FROM sm.display_name)) AND sm.is_active = true
                  ORDER BY (
                        CASE
                            WHEN st.staff_work_id IS NOT NULL AND sm.id = st.staff_work_id THEN 0
                            ELSE 1
                        END)
                 LIMIT 1) sw ON true
             LEFT JOIN LATERAL staff_profile_at(COALESCE(st.staff_commission_id, sc.id), st.sale_date) sc_eff(id, staff_member_id, effective_start_date, effective_end_date, primary_role, secondary_roles, employment_type, remuneration_plan, fte, primary_location_id, reason, created_at, created_by, updated_at, updated_by) ON true
             LEFT JOIN LATERAL staff_profile_at(COALESCE(st.staff_work_id, sw.id), st.sale_date) sw_eff(id, staff_member_id, effective_start_date, effective_end_date, primary_role, secondary_roles, employment_type, remuneration_plan, fte, primary_location_id, reason, created_at, created_by, updated_at, updated_by) ON true
             LEFT JOIN remuneration_plans rp ON rp.id=private.staff_plan_id_at(COALESCE(st.staff_commission_id,sc.id),st.sale_date)
        ), derived AS (
         SELECT b.id,
            b.import_batch_id,
            b.raw_row_id,
            b.location_id,
            b.invoice,
            b.customer_name,
            b.sale_datetime,
            b.sale_date,
            b.day_name,
            b.month_start,
            b.month_num,
            b.product_service_name,
            b.product_master_id,
            b.raw_product_type,
            b.existing_product_type_actual,
            b.existing_product_type_short,
            b.existing_commission_product_service,
            b.quantity,
            b.price_ex_gst,
            b.price_incl_gst,
            b.price_gst_component,
            b.staff_commission_name,
            b.staff_work_name,
            b.existing_staff_paid_name,
            b.staff_commission_id,
            b.staff_work_id,
            b.staff_paid_id,
            b.staff_commission_type,
            b.staff_work_type,
            b.staff_paid_type,
            b.existing_assistant_usage_alert,
            b.staff_work_is_staff_paid,
            b.invoice_header,
            b.product_header,
            b.created_at,
            b.updated_at,
            b.master_product_description,
            b.master_product_type,
            b.commission_display_name,
            b.commission_full_name,
            b.commission_primary_role,
            b.commission_remuneration_plan,
            b.commission_employment_type,
            b.work_display_name,
            b.work_full_name,
            b.work_primary_role,
            b.work_remuneration_plan,
            b.work_employment_type,
            b.commission_plan_name,
            b.commission_can_use_assistants,
                CASE
                    WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                    WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                    WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                    CASE
                        WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                        ELSE b.raw_product_type
                    END
                    ELSE b.master_product_type
                END AS product_type_actual_derived,
                CASE
                    WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Prof. Prod.'::text
                    WHEN
                    CASE
                        WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                        CASE
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                            ELSE b.raw_product_type
                        END
                        ELSE b.master_product_type
                    END = 'Retail Product'::text THEN 'Retail Prod.'::text
                    WHEN
                    CASE
                        WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                        CASE
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                            ELSE b.raw_product_type
                        END
                        ELSE b.master_product_type
                    END = 'Professional Product'::text THEN 'Prof. Prod.'::text
                    WHEN
                    CASE
                        WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                        CASE
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                            ELSE b.raw_product_type
                        END
                        ELSE b.master_product_type
                    END = 'Service'::text THEN 'Services'::text
                    ELSE
                    CASE
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        ELSE
                        CASE
                            WHEN b.master_product_type IS NOT NULL AND TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) <> ''::text THEN b.master_product_type
                            ELSE b.raw_product_type
                        END
                    END
                END AS product_type_short_derived,
                CASE
                    WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Comm - Products'::text
                    WHEN
                    CASE
                        WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                        CASE
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                            ELSE b.raw_product_type
                        END
                        ELSE b.master_product_type
                    END = 'Retail Product'::text THEN 'Comm - Products'::text
                    WHEN
                    CASE
                        WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                        CASE
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                            ELSE b.raw_product_type
                        END
                        ELSE b.master_product_type
                    END = 'Professional Product'::text THEN 'Comm - Products'::text
                    WHEN
                    CASE
                        WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                        CASE
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                            ELSE b.raw_product_type
                        END
                        ELSE b.master_product_type
                    END = 'Service'::text THEN 'Comm - Services'::text
                    ELSE '-'::text
                END AS commission_product_service_derived,
                CASE
                    WHEN upper(TRIM(BOTH FROM COALESCE(b.work_primary_role, ''::text))) = 'INTERNAL'::text THEN NULL::text
                    WHEN upper(TRIM(BOTH FROM COALESCE(b.work_primary_role, ''::text))) = 'ASSISTANT'::text AND COALESCE(b.commission_can_use_assistants, false) = false THEN NULL::text
                    WHEN upper(TRIM(BOTH FROM COALESCE(b.work_primary_role, ''::text))) = 'ASSISTANT'::text AND COALESCE(b.commission_can_use_assistants, false) = true THEN b.staff_commission_name
                    WHEN lower(TRIM(BOTH FROM COALESCE(b.work_remuneration_plan, ''::text))) = 'wage'::text AND (COALESCE(b.raw_product_type, ''::text) <> ALL (ARRAY['Voucher'::text, 'Unclassified'::text])) AND NOT (lower(TRIM(BOTH FROM COALESCE(b.product_service_name, ''::text))) = ANY (ARRAY['green fee'::text, 'redo'::text, 'training product'::text, 'miscellaneous'::text])) AND NOT upper(COALESCE(b.product_header, ''::text)) ~~ '%TONER WITH OTHER SERVICE%'::text AND NOT upper(COALESCE(b.product_header, ''::text)) ~~ '%BONDED EXTENSIONS%'::text AND NOT upper(COALESCE(b.product_header, ''::text)) ~~ '%EXTENSIONS BONDS%'::text AND NOT upper(COALESCE(b.product_header, ''::text)) ~~ '%EXTENSIONS (TAPES%'::text AND
                    CASE
                        WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                        CASE
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                            ELSE b.raw_product_type
                        END
                        ELSE b.master_product_type
                    END = 'Retail Product'::text THEN b.staff_work_name
                    WHEN upper(TRIM(BOTH FROM COALESCE(b.work_primary_role, ''::text))) <> 'INTERNAL'::text AND (lower(TRIM(BOTH FROM COALESCE(b.staff_work_is_staff_paid, ''::text))) = 'yes'::text OR NULLIF(TRIM(BOTH FROM COALESCE(b.staff_work_name, ''::text)), ''::text) IS NOT NULL AND lower(TRIM(BOTH FROM COALESCE(b.staff_commission_name, ''::text))) = lower(TRIM(BOTH FROM COALESCE(b.staff_work_name, ''::text)))) THEN COALESCE(NULLIF(TRIM(BOTH FROM COALESCE(b.work_display_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(b.staff_work_name, ''::text)), ''::text))
                    WHEN lower(TRIM(BOTH FROM COALESCE(b.work_remuneration_plan, ''::text))) = 'wage'::text THEN NULL::text
                    ELSE b.staff_work_name
                END AS staff_paid_name_derived,
                CASE
                    WHEN upper(TRIM(BOTH FROM COALESCE(b.work_primary_role, ''::text))) = 'ASSISTANT'::text AND b.commission_can_use_assistants = false THEN 'Ineligible assistant usage'::text
                    ELSE NULL::text
                END AS assistant_usage_alert_derived,
                CASE
                    WHEN b.staff_commission_name = b.staff_work_name THEN 'Yes'::text
                    ELSE 'No'::text
                END AS staff_work_is_staff_paid_dax_parity,
                CASE
                    WHEN lower(TRIM(BOTH FROM COALESCE(b.product_service_name, ''::text))) = 'green fee'::text THEN 'no_commission_greenfee'::text
                    WHEN lower(TRIM(BOTH FROM COALESCE(b.product_service_name, ''::text))) = 'redo'::text THEN 'no_commission_redo'::text
                    WHEN lower(TRIM(BOTH FROM COALESCE(b.product_service_name, ''::text))) = 'training product'::text THEN 'no_commission_trainingproduct'::text
                    WHEN lower(TRIM(BOTH FROM COALESCE(b.product_service_name, ''::text))) = 'miscellaneous'::text THEN 'no_commission_miscellaneousproduct'::text
                    WHEN COALESCE(b.raw_product_type, ''::text) = 'Voucher'::text THEN 'no_commission_voucher'::text
                    WHEN COALESCE(b.raw_product_type, ''::text) = 'Unclassified'::text THEN 'no_commission_unclassified'::text
                    WHEN upper(COALESCE(b.product_header, ''::text)) ~~ '%TONER WITH OTHER SERVICE%'::text THEN 'toner_with_other_service'::text
                    WHEN upper(COALESCE(b.product_header, ''::text)) ~~ '%BONDED EXTENSIONS%'::text THEN 'extensions_product'::text
                    WHEN upper(COALESCE(b.product_header, ''::text)) ~~ '%EXTENSIONS BONDS%'::text THEN 'extensions_product'::text
                    WHEN upper(COALESCE(b.product_header, ''::text)) ~~ '%EXTENSIONS (TAPES%'::text THEN 'extensions_service'::text
                    WHEN
                    CASE
                        WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                        CASE
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                            ELSE b.raw_product_type
                        END
                        ELSE b.master_product_type
                    END = 'Retail Product'::text THEN 'retail_product'::text
                    WHEN
                    CASE
                        WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                        CASE
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                            ELSE b.raw_product_type
                        END
                        ELSE b.master_product_type
                    END = 'Professional Product'::text THEN 'professional_product'::text
                    WHEN
                    CASE
                        WHEN "right"(COALESCE(b.product_service_name, ''::text), 1) = '*'::text THEN 'Professional Product'::text
                        WHEN COALESCE(b.raw_product_type, ''::text) = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
                        WHEN b.master_product_type IS NULL OR TRIM(BOTH FROM COALESCE(b.master_product_type, ''::text)) = ''::text THEN
                        CASE
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Service'::text THEN 'Service'::text
                            WHEN COALESCE(b.raw_product_type, ''::text) = 'Retail'::text THEN 'Retail Product'::text
                            ELSE b.raw_product_type
                        END
                        ELSE b.master_product_type
                    END = 'Service'::text THEN 'service'::text
                    ELSE NULL::text
                END AS commission_category_final
           FROM base b
        )
 SELECT id,
    import_batch_id,
    raw_row_id,
    location_id,
    invoice,
    customer_name,
    sale_datetime,
    sale_date,
    day_name,
    month_start,
    month_num,
    product_service_name,
    product_master_id,
    raw_product_type,
    existing_product_type_actual,
    existing_product_type_short,
    existing_commission_product_service,
    quantity,
    price_ex_gst,
    price_incl_gst,
    price_gst_component,
    staff_commission_name,
    staff_work_name,
    existing_staff_paid_name,
    staff_commission_id,
    staff_work_id,
    staff_paid_id,
    staff_commission_type,
    staff_work_type,
    staff_paid_type,
    existing_assistant_usage_alert,
    staff_work_is_staff_paid,
    invoice_header,
    product_header,
    created_at,
    updated_at,
    master_product_description,
    master_product_type,
    commission_display_name,
    commission_full_name,
    commission_primary_role,
    commission_remuneration_plan,
    commission_employment_type,
    work_display_name,
    work_full_name,
    work_primary_role,
    work_remuneration_plan,
    work_employment_type,
    commission_plan_name,
    commission_can_use_assistants,
    product_type_actual_derived,
    product_type_short_derived,
    commission_product_service_derived,
    staff_paid_name_derived,
    assistant_usage_alert_derived,
    staff_work_is_staff_paid_dax_parity,
    commission_category_final
   FROM derived d;

CREATE OR REPLACE VIEW public.v_sales_transactions_enriched AS WITH base AS (
         SELECT st.id,
            st.import_batch_id,
            st.raw_row_id,
            st.location_id,
            st.invoice,
            st.customer_name,
            st.sale_datetime,
            st.sale_date,
            st.day_name,
            st.month_start,
            st.month_num,
            st.product_service_name,
            st.product_master_id,
            st.raw_product_type,
            st.product_type_actual,
            st.product_type_short,
            st.commission_product_service,
            st.quantity,
            st.price_ex_gst,
            st.price_incl_gst,
            st.price_gst_component,
            st.staff_work_name,
            st.staff_work_id,
            st.staff_work_type,
            st.staff_paid_name,
            st.staff_paid_id,
            st.staff_paid_type,
            st.staff_commission_name,
            st.staff_commission_id,
            st.staff_commission_type,
            st.assistant_usage_alert AS assistant_usage_alert_source,
            st.staff_work_is_staff_paid,
            st.invoice_header,
            st.product_header,
            COALESCE(sw.display_name, NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text)) AS staff_work_display_name,
            COALESCE(sw.full_name, NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text)) AS staff_work_full_name,
            COALESCE(sw_eff.primary_role, sw.primary_role) AS staff_work_primary_role,
            (SELECT plan_name FROM public.remuneration_plans WHERE id=private.staff_plan_id_at(COALESCE(st.staff_work_id,sw.id),st.sale_date)) AS staff_work_remuneration_plan,
            COALESCE(sw_eff.employment_type, sw.employment_type) AS staff_work_employment_type,
            sw.is_active AS staff_work_is_active,
            COALESCE(sp.display_name, NULLIF(TRIM(BOTH FROM COALESCE(st.staff_paid_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, ''::text)), ''::text)) AS staff_paid_display_name,
            COALESCE(sp.full_name, NULLIF(TRIM(BOTH FROM COALESCE(st.staff_paid_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, ''::text)), ''::text)) AS staff_paid_full_name,
            COALESCE(sp_eff.primary_role, sp.primary_role) AS staff_paid_primary_role,
            (SELECT plan_name FROM public.remuneration_plans WHERE id=private.staff_plan_id_at(COALESCE(st.staff_paid_id,sp.id),st.sale_date)) AS staff_paid_remuneration_plan,
            COALESCE(sp_eff.employment_type, sp.employment_type) AS staff_paid_employment_type,
            sp.is_active AS staff_paid_is_active,
            COALESCE(sc.display_name, NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, ''::text)), ''::text)) AS staff_commission_display_name,
            COALESCE(sc.full_name, NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, ''::text)), ''::text)) AS staff_commission_full_name,
            COALESCE(sc_eff.primary_role, sc.primary_role) AS staff_commission_primary_role,
            (SELECT plan_name FROM public.remuneration_plans WHERE id=private.staff_plan_id_at(COALESCE(st.staff_commission_id,sc.id),st.sale_date)) AS staff_commission_remuneration_plan,
            COALESCE(sc_eff.employment_type, sc.employment_type) AS staff_commission_employment_type,
            sc.is_active AS staff_commission_is_active,
            st.created_at,
            st.updated_at
           FROM sales_transactions st
             LEFT JOIN LATERAL ( SELECT sm.id,
                    sm.full_name,
                    sm.display_name,
                    sm.primary_role,
                    sm.remuneration_plan,
                    sm.employment_type,
                    sm.is_active,
                    sm.first_seen_sale_date,
                    sm.last_seen_sale_date,
                    sm.notes,
                    sm.created_at,
                    sm.updated_at,
                    sm.secondary_roles,
                    sm.fte,
                    sm.employment_start_date,
                    sm.employment_end_date,
                    sm.contractor_company_name,
                    sm.contractor_gst_registered,
                    sm.contractor_ird_number,
                    sm.contractor_street_address,
                    sm.contractor_suburb,
                    sm.contractor_city_postcode,
                    sm.primary_location_id,
                    sm.contractor_email,
                    sm.contractor_invoice_name,
                    sm.contractor_invoice_code
                   FROM staff_members sm
                  WHERE st.staff_work_id IS NOT NULL AND sm.id = st.staff_work_id OR st.staff_work_id IS NULL AND NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, ''::text)), ''::text) IS NOT NULL AND lower(TRIM(BOTH FROM st.staff_work_name)) = lower(TRIM(BOTH FROM sm.display_name)) AND sm.is_active = true
                  ORDER BY (
                        CASE
                            WHEN st.staff_work_id IS NOT NULL AND sm.id = st.staff_work_id THEN 0
                            ELSE 1
                        END)
                 LIMIT 1) sw ON true
             LEFT JOIN LATERAL ( SELECT sm.id,
                    sm.full_name,
                    sm.display_name,
                    sm.primary_role,
                    sm.remuneration_plan,
                    sm.employment_type,
                    sm.is_active,
                    sm.first_seen_sale_date,
                    sm.last_seen_sale_date,
                    sm.notes,
                    sm.created_at,
                    sm.updated_at,
                    sm.secondary_roles,
                    sm.fte,
                    sm.employment_start_date,
                    sm.employment_end_date,
                    sm.contractor_company_name,
                    sm.contractor_gst_registered,
                    sm.contractor_ird_number,
                    sm.contractor_street_address,
                    sm.contractor_suburb,
                    sm.contractor_city_postcode,
                    sm.primary_location_id,
                    sm.contractor_email,
                    sm.contractor_invoice_name,
                    sm.contractor_invoice_code
                   FROM staff_members sm
                  WHERE st.staff_paid_id IS NOT NULL AND sm.id = st.staff_paid_id OR st.staff_paid_id IS NULL AND NULLIF(TRIM(BOTH FROM COALESCE(st.staff_paid_name, ''::text)), ''::text) IS NOT NULL AND lower(TRIM(BOTH FROM st.staff_paid_name)) = lower(TRIM(BOTH FROM sm.display_name)) AND sm.is_active = true
                  ORDER BY (
                        CASE
                            WHEN st.staff_paid_id IS NOT NULL AND sm.id = st.staff_paid_id THEN 0
                            ELSE 1
                        END)
                 LIMIT 1) sp ON true
             LEFT JOIN LATERAL ( SELECT sm.id,
                    sm.full_name,
                    sm.display_name,
                    sm.primary_role,
                    sm.remuneration_plan,
                    sm.employment_type,
                    sm.is_active,
                    sm.first_seen_sale_date,
                    sm.last_seen_sale_date,
                    sm.notes,
                    sm.created_at,
                    sm.updated_at,
                    sm.secondary_roles,
                    sm.fte,
                    sm.employment_start_date,
                    sm.employment_end_date,
                    sm.contractor_company_name,
                    sm.contractor_gst_registered,
                    sm.contractor_ird_number,
                    sm.contractor_street_address,
                    sm.contractor_suburb,
                    sm.contractor_city_postcode,
                    sm.primary_location_id,
                    sm.contractor_email,
                    sm.contractor_invoice_name,
                    sm.contractor_invoice_code
                   FROM staff_members sm
                  WHERE st.staff_commission_id IS NOT NULL AND sm.id = st.staff_commission_id OR st.staff_commission_id IS NULL AND NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, ''::text)), ''::text) IS NOT NULL AND lower(TRIM(BOTH FROM st.staff_commission_name)) = lower(TRIM(BOTH FROM sm.display_name)) AND sm.is_active = true
                  ORDER BY (
                        CASE
                            WHEN st.staff_commission_id IS NOT NULL AND sm.id = st.staff_commission_id THEN 0
                            ELSE 1
                        END)
                 LIMIT 1) sc ON true
             LEFT JOIN LATERAL staff_profile_at(COALESCE(st.staff_work_id, sw.id), st.sale_date) sw_eff(id, staff_member_id, effective_start_date, effective_end_date, primary_role, secondary_roles, employment_type, remuneration_plan, fte, primary_location_id, reason, created_at, created_by, updated_at, updated_by) ON true
             LEFT JOIN LATERAL staff_profile_at(COALESCE(st.staff_paid_id, sp.id), st.sale_date) sp_eff(id, staff_member_id, effective_start_date, effective_end_date, primary_role, secondary_roles, employment_type, remuneration_plan, fte, primary_location_id, reason, created_at, created_by, updated_at, updated_by) ON true
             LEFT JOIN LATERAL staff_profile_at(COALESCE(st.staff_commission_id, sc.id), st.sale_date) sc_eff(id, staff_member_id, effective_start_date, effective_end_date, primary_role, secondary_roles, employment_type, remuneration_plan, fte, primary_location_id, reason, created_at, created_by, updated_at, updated_by) ON true
        ), classified AS (
         SELECT b.id,
            b.import_batch_id,
            b.raw_row_id,
            b.location_id,
            b.invoice,
            b.customer_name,
            b.sale_datetime,
            b.sale_date,
            b.day_name,
            b.month_start,
            b.month_num,
            b.product_service_name,
            b.product_master_id,
            b.raw_product_type,
            b.product_type_actual,
            b.product_type_short,
            b.commission_product_service,
            b.quantity,
            b.price_ex_gst,
            b.price_incl_gst,
            b.price_gst_component,
            b.staff_work_name,
            b.staff_work_id,
            b.staff_work_type,
            b.staff_paid_name,
            b.staff_paid_id,
            b.staff_paid_type,
            b.staff_commission_name,
            b.staff_commission_id,
            b.staff_commission_type,
            b.assistant_usage_alert_source,
            b.staff_work_is_staff_paid,
            b.invoice_header,
            b.product_header,
            b.staff_work_display_name,
            b.staff_work_full_name,
            b.staff_work_primary_role,
            b.staff_work_remuneration_plan,
            b.staff_work_employment_type,
            b.staff_work_is_active,
            b.staff_paid_display_name,
            b.staff_paid_full_name,
            b.staff_paid_primary_role,
            b.staff_paid_remuneration_plan,
            b.staff_paid_employment_type,
            b.staff_paid_is_active,
            b.staff_commission_display_name,
            b.staff_commission_full_name,
            b.staff_commission_primary_role,
            b.staff_commission_remuneration_plan,
            b.staff_commission_employment_type,
            b.staff_commission_is_active,
            b.created_at,
            b.updated_at,
                CASE
                    WHEN COALESCE(lower(TRIM(BOTH FROM b.commission_product_service)), ''::text) ~~ '%service%'::text THEN 'service'::text
                    WHEN COALESCE(lower(TRIM(BOTH FROM b.commission_product_service)), ''::text) ~~ '%retail%'::text THEN 'retail'::text
                    WHEN COALESCE(lower(TRIM(BOTH FROM b.product_type_actual)), ''::text) ~~ '%service%'::text THEN 'service'::text
                    WHEN COALESCE(lower(TRIM(BOTH FROM b.product_type_short)), ''::text) ~~ '%service%'::text THEN 'service'::text
                    WHEN COALESCE(lower(TRIM(BOTH FROM b.raw_product_type)), ''::text) ~~ '%service%'::text THEN 'service'::text
                    ELSE 'other'::text
                END AS transaction_class,
                CASE
                    WHEN COALESCE(lower(TRIM(BOTH FROM b.staff_work_primary_role)), ''::text) = 'assistant'::text THEN true
                    ELSE false
                END AS is_assistant_work,
                CASE
                    WHEN COALESCE(lower(TRIM(BOTH FROM b.staff_paid_primary_role)), ''::text) = 'assistant'::text THEN true
                    ELSE false
                END AS is_assistant_paid,
                CASE
                    WHEN COALESCE(lower(TRIM(BOTH FROM b.staff_commission_primary_role)), ''::text) = 'assistant'::text THEN true
                    ELSE false
                END AS is_assistant_commission,
                CASE
                    WHEN COALESCE(lower(TRIM(BOTH FROM b.staff_work_remuneration_plan)), ''::text) = 'wage'::text THEN true
                    ELSE false
                END AS is_waged_work_staff,
                CASE
                    WHEN COALESCE(lower(TRIM(BOTH FROM b.staff_paid_remuneration_plan)), ''::text) = 'wage'::text THEN true
                    ELSE false
                END AS is_waged_paid_staff,
                CASE
                    WHEN b.staff_work_id IS NOT NULL AND b.staff_paid_id IS NOT NULL AND b.staff_work_id <> b.staff_paid_id THEN true
                    ELSE false
                END AS work_paid_mismatch,
                CASE
                    WHEN b.staff_work_id IS NOT NULL AND b.staff_commission_id IS NOT NULL AND b.staff_work_id <> b.staff_commission_id THEN true
                    ELSE false
                END AS work_commission_mismatch,
                CASE
                    WHEN b.staff_work_id IS NOT NULL AND COALESCE(lower(TRIM(BOTH FROM b.staff_work_primary_role)), ''::text) = 'assistant'::text AND COALESCE(lower(TRIM(BOTH FROM b.staff_work_remuneration_plan)), ''::text) = 'wage'::text AND (b.staff_paid_id IS NOT NULL AND b.staff_work_id <> b.staff_paid_id OR b.staff_paid_id IS NULL AND b.staff_commission_id IS NOT NULL AND b.staff_work_id <> b.staff_commission_id) THEN true
                    ELSE false
                END AS assistant_redirect_candidate,
                CASE
                    WHEN b.staff_work_id IS NULL AND NULLIF(TRIM(BOTH FROM COALESCE(b.staff_work_name, ''::text)), ''::text) IS NOT NULL THEN 'unmatched_work_staff'::text
                    WHEN b.staff_paid_id IS NULL AND NULLIF(TRIM(BOTH FROM COALESCE(b.staff_paid_name, ''::text)), ''::text) IS NOT NULL THEN 'unmatched_paid_staff'::text
                    WHEN b.staff_commission_id IS NULL AND NULLIF(TRIM(BOTH FROM COALESCE(b.staff_commission_name, ''::text)), ''::text) IS NOT NULL THEN 'unmatched_commission_staff'::text
                    WHEN b.staff_work_id IS NOT NULL AND COALESCE(lower(TRIM(BOTH FROM b.staff_work_primary_role)), ''::text) = 'assistant'::text AND COALESCE(lower(TRIM(BOTH FROM b.staff_work_remuneration_plan)), ''::text) = 'wage'::text AND (b.staff_paid_id IS NOT NULL AND b.staff_work_id <> b.staff_paid_id OR b.staff_paid_id IS NULL AND b.staff_commission_id IS NOT NULL AND b.staff_work_id <> b.staff_commission_id) THEN 'assistant_work_redirect_candidate'::text
                    WHEN b.staff_work_id IS NOT NULL AND b.staff_paid_id IS NOT NULL AND b.staff_work_id <> b.staff_paid_id THEN 'work_paid_mismatch'::text
                    ELSE NULL::text
                END AS review_flag
           FROM base b
        )
 SELECT id,
    import_batch_id,
    raw_row_id,
    location_id,
    invoice,
    customer_name,
    sale_datetime,
    sale_date,
    day_name,
    month_start,
    month_num,
    product_service_name,
    product_master_id,
    raw_product_type,
    product_type_actual,
    product_type_short,
    commission_product_service,
    quantity,
    price_ex_gst,
    price_incl_gst,
    price_gst_component,
    staff_work_name,
    staff_work_id,
    staff_work_type,
    staff_paid_name,
    staff_paid_id,
    staff_paid_type,
    staff_commission_name,
    staff_commission_id,
    staff_commission_type,
    assistant_usage_alert_source,
    staff_work_is_staff_paid,
    invoice_header,
    product_header,
    staff_work_display_name,
    staff_work_full_name,
    staff_work_primary_role,
    staff_work_remuneration_plan,
    staff_work_employment_type,
    staff_work_is_active,
    staff_paid_display_name,
    staff_paid_full_name,
    staff_paid_primary_role,
    staff_paid_remuneration_plan,
    staff_paid_employment_type,
    staff_paid_is_active,
    staff_commission_display_name,
    staff_commission_full_name,
    staff_commission_primary_role,
    staff_commission_remuneration_plan,
    staff_commission_employment_type,
    staff_commission_is_active,
    created_at,
    updated_at,
    transaction_class,
    is_assistant_work,
    is_assistant_paid,
    is_assistant_commission,
    is_waged_work_staff,
    is_waged_paid_staff,
    work_paid_mismatch,
    work_commission_mismatch,
    assistant_redirect_candidate,
    review_flag,
        CASE
            WHEN assistant_redirect_candidate THEN COALESCE(staff_paid_id, staff_commission_id)
            WHEN staff_commission_id IS NOT NULL THEN staff_commission_id
            WHEN staff_paid_id IS NOT NULL THEN staff_paid_id
            ELSE staff_work_id
        END AS commission_owner_candidate_id,
        CASE
            WHEN assistant_redirect_candidate THEN COALESCE(staff_paid_display_name, staff_commission_display_name)
            WHEN staff_commission_id IS NOT NULL THEN staff_commission_display_name
            WHEN staff_paid_id IS NOT NULL THEN staff_paid_display_name
            ELSE staff_work_display_name
        END AS commission_owner_candidate_name,
        CASE
            WHEN assistant_redirect_candidate THEN 'assistant_work_redirected_to_paid_staff'::text
            WHEN staff_commission_id IS NOT NULL THEN 'explicit_commission_staff'::text
            WHEN staff_paid_id IS NOT NULL THEN 'paid_staff_fallback'::text
            WHEN staff_work_id IS NOT NULL THEN 'work_staff_fallback'::text
            ELSE 'unassigned'::text
        END AS commission_owner_rule
   FROM classified c;

CREATE OR REPLACE VIEW public.v_commission_calculations_core AS WITH parity AS (
         SELECT v.id,
            v.import_batch_id,
            v.raw_row_id,
            v.location_id,
            v.invoice,
            v.customer_name,
            v.sale_datetime,
            v.sale_date,
            v.day_name,
            v.month_start,
            v.month_num,
            v.product_service_name,
            v.product_master_id,
            v.raw_product_type,
            v.existing_product_type_actual,
            v.existing_product_type_short,
            v.existing_commission_product_service,
            v.quantity,
            v.price_ex_gst,
            v.price_incl_gst,
            v.price_gst_component,
            v.staff_commission_name,
            v.staff_work_name,
            v.existing_staff_paid_name,
            v.staff_commission_id,
            v.staff_work_id,
            v.staff_paid_id,
            v.staff_commission_type,
            v.staff_work_type,
            v.staff_paid_type,
            v.existing_assistant_usage_alert,
            v.staff_work_is_staff_paid,
            v.invoice_header,
            v.product_header,
            v.created_at,
            v.updated_at,
            v.master_product_description,
            v.master_product_type,
            v.commission_display_name,
            v.commission_full_name,
            v.commission_primary_role,
            v.commission_remuneration_plan,
            v.commission_employment_type,
            v.work_display_name,
            v.work_full_name,
            v.work_primary_role,
            v.work_remuneration_plan,
            v.work_employment_type,
            v.commission_plan_name,
            v.commission_can_use_assistants,
            v.product_type_actual_derived,
            v.product_type_short_derived,
            v.commission_product_service_derived,
            v.staff_paid_name_derived,
            v.assistant_usage_alert_derived,
            v.staff_work_is_staff_paid_dax_parity,
            v.commission_category_final
           FROM v_sales_transactions_powerbi_parity v
        ), paid_staff_resolved AS (
         SELECT p.id,
            p.import_batch_id,
            p.raw_row_id,
            p.location_id,
            p.invoice,
            p.customer_name,
            p.sale_datetime,
            p.sale_date,
            p.day_name,
            p.month_start,
            p.month_num,
            p.product_service_name,
            p.product_master_id,
            p.raw_product_type,
            p.existing_product_type_actual,
            p.existing_product_type_short,
            p.existing_commission_product_service,
            p.quantity,
            p.price_ex_gst,
            p.price_incl_gst,
            p.price_gst_component,
            p.staff_commission_name,
            p.staff_work_name,
            p.existing_staff_paid_name,
            p.staff_commission_id,
            p.staff_work_id,
            p.staff_paid_id,
            p.staff_commission_type,
            p.staff_work_type,
            p.staff_paid_type,
            p.existing_assistant_usage_alert,
            p.staff_work_is_staff_paid,
            p.invoice_header,
            p.product_header,
            p.created_at,
            p.updated_at,
            p.master_product_description,
            p.master_product_type,
            p.commission_display_name,
            p.commission_full_name,
            p.commission_primary_role,
            p.commission_remuneration_plan,
            p.commission_employment_type,
            p.work_display_name,
            p.work_full_name,
            p.work_primary_role,
            p.work_remuneration_plan,
            p.work_employment_type,
            p.commission_plan_name,
            p.commission_can_use_assistants,
            p.product_type_actual_derived,
            p.product_type_short_derived,
            p.commission_product_service_derived,
            p.staff_paid_name_derived,
            p.assistant_usage_alert_derived,
            p.staff_work_is_staff_paid_dax_parity,
            p.commission_category_final,
            sm_paid.id AS derived_staff_paid_id,
            COALESCE(sm_paid.display_name, NULLIF(TRIM(BOTH FROM COALESCE(p.staff_paid_name_derived, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(p.existing_staff_paid_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(p.staff_commission_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(p.staff_work_name, ''::text)), ''::text)) AS derived_staff_paid_display_name,
            COALESCE(sm_paid.full_name, NULLIF(TRIM(BOTH FROM COALESCE(p.staff_paid_name_derived, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(p.existing_staff_paid_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(p.staff_commission_name, ''::text)), ''::text), NULLIF(TRIM(BOTH FROM COALESCE(p.staff_work_name, ''::text)), ''::text)) AS derived_staff_paid_full_name,
            COALESCE(sm_paid_eff.primary_role, sm_paid.primary_role) AS derived_staff_paid_primary_role,
            (SELECT plan_name FROM public.remuneration_plans WHERE id=private.staff_plan_id_at(sm_paid.id,p.sale_date)) AS derived_staff_paid_remuneration_plan,
            COALESCE(sm_paid_eff.employment_type, sm_paid.employment_type) AS derived_staff_paid_employment_type,
            rp_paid.id AS derived_staff_paid_plan_id,
            rp_paid.plan_name AS derived_staff_paid_plan_name,
            rp_commission.id AS benchmark_commission_plan_id,
            rp_commission.plan_name AS benchmark_commission_plan_name,
            rp_commission.can_use_assistants AS benchmark_commission_can_use_assistants
           FROM parity p
             LEFT JOIN staff_members sm_paid ON p.staff_paid_name_derived IS NOT NULL AND lower(TRIM(BOTH FROM p.staff_paid_name_derived)) = lower(TRIM(BOTH FROM sm_paid.display_name)) OR p.staff_paid_name_derived IS NULL AND p.staff_work_id IS NOT NULL AND p.staff_work_is_staff_paid_dax_parity = 'Yes'::text AND sm_paid.id = p.staff_work_id
             LEFT JOIN LATERAL staff_profile_at(sm_paid.id, p.sale_date) sm_paid_eff(id, staff_member_id, effective_start_date, effective_end_date, primary_role, secondary_roles, employment_type, remuneration_plan, fte, primary_location_id, reason, created_at, created_by, updated_at, updated_by) ON true
             LEFT JOIN remuneration_plans rp_paid ON rp_paid.id=private.staff_plan_id_at(sm_paid.id,p.sale_date)
             LEFT JOIN remuneration_plans rp_commission ON rp_commission.id=private.benchmark_plan_id_at(p.sale_date)
        ), rated AS (
         SELECT psr.id,
            psr.import_batch_id,
            psr.raw_row_id,
            psr.location_id,
            psr.invoice,
            psr.customer_name,
            psr.sale_datetime,
            psr.sale_date,
            psr.day_name,
            psr.month_start,
            psr.month_num,
            psr.product_service_name,
            psr.product_master_id,
            psr.raw_product_type,
            psr.existing_product_type_actual,
            psr.existing_product_type_short,
            psr.existing_commission_product_service,
            psr.quantity,
            psr.price_ex_gst,
            psr.price_incl_gst,
            psr.price_gst_component,
            psr.staff_commission_name,
            psr.staff_work_name,
            psr.existing_staff_paid_name,
            psr.staff_commission_id,
            psr.staff_work_id,
            psr.staff_paid_id,
            psr.staff_commission_type,
            psr.staff_work_type,
            psr.staff_paid_type,
            psr.existing_assistant_usage_alert,
            psr.staff_work_is_staff_paid,
            psr.invoice_header,
            psr.product_header,
            psr.created_at,
            psr.updated_at,
            psr.master_product_description,
            psr.master_product_type,
            psr.commission_display_name,
            psr.commission_full_name,
            psr.commission_primary_role,
            psr.commission_remuneration_plan,
            psr.commission_employment_type,
            psr.work_display_name,
            psr.work_full_name,
            psr.work_primary_role,
            psr.work_remuneration_plan,
            psr.work_employment_type,
            psr.commission_plan_name,
            psr.commission_can_use_assistants,
            psr.product_type_actual_derived,
            psr.product_type_short_derived,
            psr.commission_product_service_derived,
            psr.staff_paid_name_derived,
            psr.assistant_usage_alert_derived,
            psr.staff_work_is_staff_paid_dax_parity,
            psr.commission_category_final,
            psr.derived_staff_paid_id,
            psr.derived_staff_paid_display_name,
            psr.derived_staff_paid_full_name,
            psr.derived_staff_paid_primary_role,
            psr.derived_staff_paid_remuneration_plan,
            psr.derived_staff_paid_employment_type,
            psr.derived_staff_paid_plan_id,
            psr.derived_staff_paid_plan_name,
            psr.benchmark_commission_plan_id,
            psr.benchmark_commission_plan_name,
            psr.benchmark_commission_can_use_assistants,
            apr.rate AS actual_commission_rate,
            tpr.rate AS theoretical_commission_rate
           FROM paid_staff_resolved psr
             LEFT JOIN remuneration_plan_rates apr ON apr.remuneration_plan_id = psr.derived_staff_paid_plan_id AND lower(TRIM(BOTH FROM apr.commission_category)) = lower(TRIM(BOTH FROM psr.commission_category_final))
             LEFT JOIN remuneration_plan_rates tpr ON tpr.remuneration_plan_id = psr.benchmark_commission_plan_id AND lower(TRIM(BOTH FROM tpr.commission_category)) = lower(TRIM(BOTH FROM psr.commission_category_final))
        ) , costed AS (
 SELECT rated.*, b.*, private.service_id_for_sale(raw_row_id,location_id,product_service_name) AS service_cost_service_id
 FROM rated LEFT JOIN LATERAL private.service_commission_basis(
 private.service_id_for_sale(raw_row_id,location_id,product_service_name),sale_date,price_ex_gst,quantity,
 coalesce((SELECT deduct_service_product_costs FROM public.remuneration_plans WHERE id=rated.derived_staff_paid_plan_id),false),
 coalesce((SELECT deduct_service_product_costs FROM public.remuneration_plans WHERE id=rated.benchmark_commission_plan_id),false),
 product_type_actual_derived='Service' AND coalesce(commission_category_final,'') NOT LIKE 'no_commission_%'
 AND derived_staff_paid_id IS NOT NULL AND derived_staff_paid_plan_id IS NOT NULL AND lower(coalesce(staff_paid_name_derived,''))<>'internal',
 benchmark_commission_plan_id IS NOT NULL) b ON true
 )
 SELECT id,
    import_batch_id,
    raw_row_id,
    location_id,
    invoice,
    customer_name,
    sale_datetime,
    sale_date,
    day_name,
    month_start,
    month_num,
    product_service_name,
    product_master_id,
    master_product_description,
    master_product_type,
    raw_product_type,
    product_type_actual_derived,
    product_type_short_derived,
    commission_product_service_derived,
    commission_category_final,
    quantity,
    price_ex_gst,
    price_incl_gst,
    price_gst_component,
    staff_commission_name,
    staff_work_name,
    existing_staff_paid_name,
    staff_paid_name_derived,
    staff_commission_id,
    staff_work_id,
    staff_paid_id AS existing_staff_paid_id,
    derived_staff_paid_id,
    commission_display_name,
    commission_full_name,
    commission_primary_role,
    commission_remuneration_plan,
    work_display_name,
    work_full_name,
    work_primary_role,
    work_remuneration_plan,
    derived_staff_paid_display_name,
    derived_staff_paid_full_name,
    derived_staff_paid_primary_role,
    derived_staff_paid_remuneration_plan,
    derived_staff_paid_employment_type,
    derived_staff_paid_plan_id,
    derived_staff_paid_plan_name,
    commission_can_use_assistants,
    assistant_usage_alert_derived,
    staff_work_is_staff_paid_dax_parity,
        CASE
            WHEN lower(TRIM(BOTH FROM COALESCE(staff_paid_name_derived, ''::text))) = 'internal'::text THEN true
            ELSE false
        END AS is_internal_non_commission,
        CASE
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = ANY (ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text, 'no_commission_trainingproduct'::text, 'no_commission_miscellaneousproduct'::text, 'no_commission_voucher'::text, 'no_commission_unclassified'::text]) THEN true
            ELSE false
        END AS is_named_non_commission_category,
    actual_commission_rate,
        CASE
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = ANY (ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text, 'no_commission_trainingproduct'::text, 'no_commission_miscellaneousproduct'::text, 'no_commission_voucher'::text, 'no_commission_unclassified'::text]) THEN NULL::numeric
            WHEN lower(TRIM(BOTH FROM COALESCE(staff_paid_name_derived, ''::text))) <> 'internal'::text AND staff_paid_name_derived IS NOT NULL AND (derived_staff_paid_id IS NULL OR derived_staff_paid_plan_id IS NULL) THEN 0::numeric
            WHEN price_ex_gst IS NOT NULL AND actual_commission_rate IS NOT NULL THEN private.require_ready_commission(actual_commissionable_ex_gst * actual_commission_rate,service_cost_status)
            ELSE NULL::numeric
        END AS actual_commission_amt_ex_gst,
    theoretical_commission_rate,
        CASE
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = ANY (ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text, 'no_commission_trainingproduct'::text, 'no_commission_miscellaneousproduct'::text, 'no_commission_voucher'::text, 'no_commission_unclassified'::text]) THEN NULL::numeric
            WHEN lower(TRIM(BOTH FROM COALESCE(staff_paid_name_derived, ''::text))) <> 'internal'::text AND staff_paid_name_derived IS NOT NULL AND (derived_staff_paid_id IS NULL OR derived_staff_paid_plan_id IS NULL) THEN 0::numeric
            WHEN price_ex_gst IS NOT NULL AND theoretical_commission_rate IS NOT NULL THEN private.require_ready_commission(theoretical_commissionable_ex_gst * theoretical_commission_rate,service_cost_status)
            ELSE NULL::numeric
        END AS theoretical_commission_amt_ex_gst,
        CASE
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = ANY (ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text, 'no_commission_trainingproduct'::text, 'no_commission_miscellaneousproduct'::text, 'no_commission_voucher'::text, 'no_commission_unclassified'::text]) THEN NULL::numeric
            WHEN lower(TRIM(BOTH FROM COALESCE(staff_paid_name_derived, ''::text))) <> 'internal'::text AND staff_paid_name_derived IS NOT NULL AND (derived_staff_paid_id IS NULL OR derived_staff_paid_plan_id IS NULL) THEN 0::numeric
            WHEN upper(TRIM(BOTH FROM COALESCE(work_primary_role, ''::text))) = 'ASSISTANT'::text AND commission_can_use_assistants = true AND price_ex_gst IS NOT NULL AND actual_commission_rate IS NOT NULL THEN private.require_ready_commission(actual_commissionable_ex_gst * actual_commission_rate,service_cost_status)
            ELSE NULL::numeric
        END AS assistant_commission_amt_ex_gst,
        CASE
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = 'no_commission_greenfee'::text THEN 'no_commission_greenfee'::text
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = 'no_commission_redo'::text THEN 'no_commission_redo'::text
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = 'no_commission_trainingproduct'::text THEN 'no_commission_trainingproduct'::text
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = 'no_commission_miscellaneousproduct'::text THEN 'no_commission_miscellaneousproduct'::text
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = 'no_commission_voucher'::text THEN 'no_commission_voucher'::text
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = 'no_commission_unclassified'::text THEN 'no_commission_unclassified'::text
            WHEN lower(TRIM(BOTH FROM COALESCE(staff_paid_name_derived, ''::text))) = 'internal'::text THEN 'non_commission_internal'::text
            WHEN staff_paid_name_derived IS NULL AND assistant_usage_alert_derived = 'Ineligible assistant usage'::text THEN 'blocked_ineligible_assistant_usage'::text
            WHEN staff_paid_name_derived IS NULL THEN 'no_paid_staff_derived'::text
            WHEN staff_paid_name_derived IS NOT NULL AND (derived_staff_paid_id IS NULL OR derived_staff_paid_plan_id IS NULL) THEN 'non_commission_unconfigured_paid_staff'::text
            WHEN commission_category_final IS NULL THEN 'commission_category_not_derived'::text
            WHEN actual_commission_rate IS NULL THEN 'commission_rate_not_found'::text
            ELSE NULL::text
        END AS calculation_alert,
    invoice_header,
    product_header,
    created_at,
    updated_at,
        CASE
            WHEN lower(TRIM(BOTH FROM COALESCE(commission_category_final, ''::text))) = ANY (ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text, 'no_commission_trainingproduct'::text, 'no_commission_miscellaneousproduct'::text, 'no_commission_voucher'::text, 'no_commission_unclassified'::text]) THEN NULL::numeric
            WHEN lower(TRIM(BOTH FROM COALESCE(staff_paid_name_derived, ''::text))) <> 'internal'::text AND staff_paid_name_derived IS NOT NULL AND (derived_staff_paid_id IS NULL OR derived_staff_paid_plan_id IS NULL) THEN 0::numeric
            WHEN upper(TRIM(BOTH FROM COALESCE(work_primary_role, ''::text))) = 'ASSISTANT'::text AND COALESCE(benchmark_commission_can_use_assistants, false) = true AND price_ex_gst IS NOT NULL AND theoretical_commission_rate IS NOT NULL THEN private.require_ready_commission(theoretical_commissionable_ex_gst * theoretical_commission_rate,service_cost_status)
            ELSE NULL::numeric
        END AS theoretical_assistant_commission_amt_ex_gst,
 actual_product_cost_ex_gst, actual_commissionable_ex_gst, theoretical_product_cost_ex_gst, theoretical_commissionable_ex_gst, service_cost_status, service_cost_service_id
 FROM costed;

CREATE OR REPLACE VIEW public.v_commission_calculations_qa AS SELECT id,
    import_batch_id,
    raw_row_id,
    location_id,
    invoice,
    customer_name,
    sale_datetime,
    sale_date,
    day_name,
    month_start,
    month_num,
    product_service_name,
    product_master_id,
    master_product_description,
    master_product_type,
    raw_product_type,
    product_type_actual_derived,
    product_type_short_derived,
    commission_product_service_derived,
    commission_category_final,
    quantity,
    price_ex_gst,
    price_incl_gst,
    price_gst_component,
    staff_commission_name,
    staff_work_name,
    existing_staff_paid_name,
    staff_paid_name_derived,
    staff_commission_id,
    staff_work_id,
    existing_staff_paid_id,
    derived_staff_paid_id,
    commission_display_name,
    commission_full_name,
    commission_primary_role,
    commission_remuneration_plan,
    work_display_name,
    work_full_name,
    work_primary_role,
    work_remuneration_plan,
    derived_staff_paid_display_name,
    derived_staff_paid_full_name,
    derived_staff_paid_primary_role,
    derived_staff_paid_remuneration_plan,
    derived_staff_paid_employment_type,
    derived_staff_paid_plan_id,
    derived_staff_paid_plan_name,
    commission_can_use_assistants,
    assistant_usage_alert_derived,
    staff_work_is_staff_paid_dax_parity,
    is_internal_non_commission,
    is_named_non_commission_category,
    actual_commission_rate,
    actual_commission_amt_ex_gst,
    theoretical_commission_rate,
    theoretical_commission_amt_ex_gst,
    assistant_commission_amt_ex_gst,
    calculation_alert,
    invoice_header,
    product_header,
    created_at,
    updated_at,
        CASE
            WHEN calculation_alert IS NULL THEN 'clean_commission_row'::text
            WHEN calculation_alert = ANY (ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text, 'no_commission_trainingproduct'::text, 'no_commission_miscellaneousproduct'::text, 'no_commission_voucher'::text, 'no_commission_unclassified'::text, 'non_commission_internal'::text, 'non_commission_unconfigured_paid_staff'::text]) THEN 'expected_non_commission'::text
            WHEN calculation_alert = 'paid_staff_plan_not_matched'::text THEN 'configuration_issue'::text
            ELSE 'unexpected_issue'::text
        END AS qa_bucket,
        CASE
            WHEN calculation_alert IS NULL THEN 0
            WHEN calculation_alert = ANY (ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text, 'no_commission_trainingproduct'::text, 'no_commission_miscellaneousproduct'::text, 'no_commission_voucher'::text, 'no_commission_unclassified'::text, 'non_commission_internal'::text, 'non_commission_unconfigured_paid_staff'::text]) THEN 1
            WHEN calculation_alert = 'paid_staff_plan_not_matched'::text THEN 2
            ELSE 3
        END AS qa_priority,
    theoretical_assistant_commission_amt_ex_gst,
 c.actual_product_cost_ex_gst, c.actual_commissionable_ex_gst, c.theoretical_product_cost_ex_gst, c.theoretical_commissionable_ex_gst, c.service_cost_status, c.service_cost_service_id
   FROM v_commission_calculations_core c;

CREATE OR REPLACE VIEW public.v_admin_payroll_lines AS SELECT id,
    import_batch_id,
    raw_row_id,
    location_id,
    invoice,
    sale_datetime,
    sale_date,
    day_name,
    month_start,
    month_num,
    customer_name,
    product_service_name,
    product_master_id,
    master_product_description,
    master_product_type,
    raw_product_type,
    product_type_actual_derived AS product_type_actual,
    product_type_short_derived AS product_type_short,
    commission_product_service_derived AS commission_product_service,
    commission_category_final,
    quantity,
    price_ex_gst,
    price_incl_gst,
    price_gst_component,
    staff_commission_name,
    staff_work_name,
    existing_staff_paid_name,
    staff_paid_name_derived,
    staff_commission_id,
    staff_work_id,
    existing_staff_paid_id,
    derived_staff_paid_id,
    commission_display_name,
    commission_full_name,
    commission_primary_role,
    commission_remuneration_plan,
    work_display_name,
    work_full_name,
    work_primary_role,
    work_remuneration_plan,
    derived_staff_paid_display_name,
    derived_staff_paid_full_name,
    derived_staff_paid_primary_role,
    derived_staff_paid_remuneration_plan,
    derived_staff_paid_employment_type,
    derived_staff_paid_plan_id,
    derived_staff_paid_plan_name,
    commission_can_use_assistants,
    assistant_usage_alert_derived,
    staff_work_is_staff_paid_dax_parity,
    is_internal_non_commission,
    is_named_non_commission_category,
    actual_commission_rate,
    actual_commission_amt_ex_gst,
    theoretical_commission_rate,
    theoretical_commission_amt_ex_gst,
    assistant_commission_amt_ex_gst,
    calculation_alert,
    qa_bucket,
    qa_priority,
        CASE
            WHEN qa_bucket = 'clean_commission_row'::text AND COALESCE(actual_commission_amt_ex_gst, 0::numeric) <> 0::numeric THEN 'payable'::text
            WHEN qa_bucket = 'clean_commission_row'::text AND COALESCE(actual_commission_amt_ex_gst, 0::numeric) = 0::numeric THEN 'zero_value_commission_row'::text
            WHEN qa_bucket = 'expected_non_commission'::text THEN 'expected_no_commission'::text
            WHEN qa_bucket = 'configuration_issue'::text THEN 'hold_config_issue'::text
            WHEN qa_bucket = 'unexpected_issue'::text THEN 'hold_unexpected_issue'::text
            ELSE 'hold_unknown'::text
        END AS payroll_status,
        CASE
            WHEN qa_bucket = 'clean_commission_row'::text AND COALESCE(actual_commission_amt_ex_gst, 0::numeric) <> 0::numeric THEN true
            ELSE false
        END AS is_payable,
        CASE
            WHEN qa_bucket = ANY (ARRAY['configuration_issue'::text, 'unexpected_issue'::text]) THEN true
            ELSE false
        END AS requires_review,
    invoice_header,
    product_header,
    created_at,
    updated_at,
    theoretical_assistant_commission_amt_ex_gst,
 q.actual_product_cost_ex_gst, q.actual_commissionable_ex_gst, q.theoretical_product_cost_ex_gst, q.theoretical_commissionable_ex_gst, q.service_cost_status, q.service_cost_service_id
   FROM v_commission_calculations_qa q;

CREATE OR REPLACE VIEW public.v_admin_payroll_lines_weekly AS SELECT l.id,
    l.import_batch_id,
    l.raw_row_id,
    l.location_id,
    l.invoice,
    l.sale_datetime,
    l.sale_date,
    l.day_name,
    l.month_start,
    l.month_num,
    l.customer_name,
    l.product_service_name,
    l.product_master_id,
    l.master_product_description,
    l.master_product_type,
    l.raw_product_type,
    l.product_type_actual,
    l.product_type_short,
    l.commission_product_service,
    l.commission_category_final,
    l.quantity,
    l.price_ex_gst,
    l.price_incl_gst,
    l.price_gst_component,
    l.staff_commission_name,
    l.staff_work_name,
    l.existing_staff_paid_name,
    l.staff_paid_name_derived,
    l.staff_commission_id,
    l.staff_work_id,
    l.existing_staff_paid_id,
    l.derived_staff_paid_id,
    l.commission_display_name,
    l.commission_full_name,
    l.commission_primary_role,
    l.commission_remuneration_plan,
    l.work_display_name,
    l.work_full_name,
    l.work_primary_role,
    l.work_remuneration_plan,
    l.derived_staff_paid_display_name,
    l.derived_staff_paid_full_name,
    l.derived_staff_paid_primary_role,
    l.derived_staff_paid_remuneration_plan,
    l.derived_staff_paid_employment_type,
    l.derived_staff_paid_plan_id,
    l.derived_staff_paid_plan_name,
    l.commission_can_use_assistants,
    l.assistant_usage_alert_derived,
    l.staff_work_is_staff_paid_dax_parity,
    l.is_internal_non_commission,
    l.is_named_non_commission_category,
    l.actual_commission_rate,
    l.actual_commission_amt_ex_gst,
    l.theoretical_commission_rate,
    l.theoretical_commission_amt_ex_gst,
    l.assistant_commission_amt_ex_gst,
    l.calculation_alert,
    l.qa_bucket,
    l.qa_priority,
    l.payroll_status,
    l.is_payable,
    l.requires_review,
    l.invoice_header,
    l.product_header,
    l.created_at,
    l.updated_at,
    (l.sale_date - (EXTRACT(isodow FROM l.sale_date)::integer - 1)::double precision * '1 day'::interval)::date AS pay_week_start,
    (l.sale_date - (EXTRACT(isodow FROM l.sale_date)::integer - 1)::double precision * '1 day'::interval + '6 days'::interval)::date AS pay_week_end,
    (l.sale_date - (EXTRACT(isodow FROM l.sale_date)::integer - 1)::double precision * '1 day'::interval + '10 days'::interval)::date AS pay_date,
    loc.name AS location_name,
    sm_paid.primary_location_id AS derived_staff_paid_primary_location_id,
    paid_loc.code AS derived_staff_paid_primary_location_code,
    paid_loc.name AS derived_staff_paid_primary_location_name,
    res_staff.final_staff_id AS resolved_derived_staff_paid_id,
    COALESCE(sm_res.display_name, l.derived_staff_paid_display_name) AS resolved_derived_staff_paid_display_name,
    COALESCE(sm_res.full_name, l.derived_staff_paid_full_name) AS resolved_derived_staff_paid_full_name,
    COALESCE(sm_res.remuneration_plan, l.derived_staff_paid_remuneration_plan) AS resolved_derived_staff_paid_remuneration_plan,
    sm_res.primary_location_id AS resolved_derived_staff_paid_primary_location_id,
    paid_loc_res.code AS resolved_derived_staff_paid_primary_location_code,
    paid_loc_res.name AS resolved_derived_staff_paid_primary_location_name,
    l.theoretical_assistant_commission_amt_ex_gst,
 l.actual_product_cost_ex_gst, l.actual_commissionable_ex_gst, l.theoretical_product_cost_ex_gst, l.theoretical_commissionable_ex_gst, l.service_cost_status, l.service_cost_service_id
   FROM v_admin_payroll_lines l
     LEFT JOIN locations loc ON loc.id = l.location_id
     LEFT JOIN staff_members sm_paid ON sm_paid.id = l.derived_staff_paid_id
     LEFT JOIN locations paid_loc ON paid_loc.id = sm_paid.primary_location_id
     LEFT JOIN LATERAL ( SELECT NULLIF(TRIM(BOTH FROM lower(COALESCE(l.derived_staff_paid_display_name, l.staff_paid_name_derived, ''::text))), ''::text) AS cand_dn,
            NULLIF(TRIM(BOTH FROM lower(COALESCE(l.derived_staff_paid_full_name, ''::text))), ''::text) AS cand_fn) nm ON true
     LEFT JOIN LATERAL ( SELECT
                CASE
                    WHEN l.derived_staff_paid_id IS NOT NULL THEN l.derived_staff_paid_id
                    WHEN nm.cand_dn IS NOT NULL AND (( SELECT count(*)::integer AS count
                       FROM staff_members sm
                      WHERE lower(TRIM(BOTH FROM sm.display_name)) = nm.cand_dn)) = 1 THEN ( SELECT sm.id
                       FROM staff_members sm
                      WHERE lower(TRIM(BOTH FROM sm.display_name)) = nm.cand_dn
                     LIMIT 1)
                    WHEN nm.cand_dn IS NOT NULL AND (( SELECT count(*)::integer AS count
                       FROM staff_members sm
                      WHERE lower(TRIM(BOTH FROM sm.full_name)) = nm.cand_dn)) = 1 THEN ( SELECT sm.id
                       FROM staff_members sm
                      WHERE lower(TRIM(BOTH FROM sm.full_name)) = nm.cand_dn
                     LIMIT 1)
                    WHEN nm.cand_fn IS NOT NULL AND nm.cand_fn IS DISTINCT FROM nm.cand_dn AND (( SELECT count(*)::integer AS count
                       FROM staff_members sm
                      WHERE lower(TRIM(BOTH FROM sm.full_name)) = nm.cand_fn)) = 1 THEN ( SELECT sm.id
                       FROM staff_members sm
                      WHERE lower(TRIM(BOTH FROM sm.full_name)) = nm.cand_fn
                     LIMIT 1)
                    WHEN nm.cand_fn IS NOT NULL AND nm.cand_fn IS DISTINCT FROM nm.cand_dn AND (( SELECT count(*)::integer AS count
                       FROM staff_members sm
                      WHERE lower(TRIM(BOTH FROM sm.display_name)) = nm.cand_fn)) = 1 THEN ( SELECT sm.id
                       FROM staff_members sm
                      WHERE lower(TRIM(BOTH FROM sm.display_name)) = nm.cand_fn
                     LIMIT 1)
                    ELSE NULL::uuid
                END AS final_staff_id) res_staff ON true
     LEFT JOIN staff_members sm_res ON sm_res.id = res_staff.final_staff_id
     LEFT JOIN locations paid_loc_res ON paid_loc_res.id = sm_res.primary_location_id;

CREATE OR REPLACE VIEW public.v_stylist_commission_lines_weekly_final AS SELECT a.user_id,
    l.id,
    l.import_batch_id,
    l.raw_row_id,
    l.location_id,
    l.invoice,
    l.sale_datetime,
    l.sale_date,
    l.day_name,
    l.month_start,
    l.month_num,
    l.pay_week_start,
    l.pay_week_end,
    l.pay_date,
    l.customer_name,
    l.product_service_name,
    l.product_type_actual,
    l.product_type_short,
    l.commission_product_service,
    l.commission_category_final,
    l.quantity,
    l.price_ex_gst,
    l.price_incl_gst,
    l.derived_staff_paid_id,
    l.derived_staff_paid_display_name,
    l.derived_staff_paid_full_name,
    l.actual_commission_rate,
    l.actual_commission_amt_ex_gst,
    l.assistant_commission_amt_ex_gst,
    l.payroll_status,
        CASE
            WHEN l.payroll_status = 'expected_no_commission'::text THEN l.calculation_alert
            WHEN l.payroll_status = 'zero_value_commission_row'::text THEN 'zero_commission_row'::text
            ELSE NULL::text
        END AS stylist_visible_note,
    a.access_role,
    l.location_name,
    l.work_display_name,
    l.work_full_name,
    l.staff_work_name,
    l.staff_paid_name_derived,
    l.existing_staff_paid_name,
 l.actual_product_cost_ex_gst, l.actual_commissionable_ex_gst, l.theoretical_product_cost_ex_gst, l.theoretical_commissionable_ex_gst, l.service_cost_status, l.service_cost_service_id
   FROM v_admin_payroll_lines_weekly l
     JOIN staff_member_user_access a ON a.is_active = true AND ((a.access_role = ANY (ARRAY['stylist'::text, 'assistant'::text])) AND a.staff_member_id = l.derived_staff_paid_id OR (a.access_role = ANY (ARRAY['manager'::text, 'admin'::text])))
  WHERE l.derived_staff_paid_id IS NOT NULL AND COALESCE(lower(TRIM(BOTH FROM l.derived_staff_paid_display_name)), ''::text) <> 'internal'::text AND COALESCE(l.calculation_alert, ''::text) <> 'non_commission_unconfigured_paid_staff'::text;

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


-- Commission guide: permanent plan identity and the shared date-aware cost basis.
-- Auth/scope guards and existing classification/rate rules are retained.
CREATE OR REPLACE FUNCTION public.get_staff_commission_guide(p_staff_member_id uuid DEFAULT NULL::uuid, p_as_of_date date DEFAULT CURRENT_DATE)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_temp'
AS $function$
DECLARE
  v_caller       uuid    := auth.uid();
  v_caller_staff uuid;
  v_target       uuid;
  v_elevated     boolean := false;
  v_as_of        date    := COALESCE(p_as_of_date, current_date);
  v_lookback_start date;
  v_fallback_start date;

  v_staff_row    record;
  v_profile      record;
  v_plan         record;
  v_section      jsonb;
  v_example      jsonb;
  v_basis        record;
  v_adjusted_sections jsonb := '[]'::jsonb;
  v_rates_map    jsonb   := '{}'::jsonb;

  v_rate_service        numeric;
  v_rate_retail         numeric;
  v_rate_professional   numeric;
  v_rate_toner          numeric;
  v_rate_ext_product    numeric;
  v_rate_ext_service    numeric;

  v_rate_cards          jsonb;
  v_classification      jsonb;
  v_admin_full_guide    jsonb := '[]'::jsonb;
  v_summary             jsonb;
  v_notes               jsonb;

  v_eligible_sections     jsonb := '[]'::jsonb;
  v_not_eligible_sections jsonb := '[]'::jsonb;
  v_recent_items          jsonb := '[]'::jsonb;
  v_examples_map          jsonb := '{}'::jsonb;

  v_eff_role            text;
  v_eff_secondary_roles text;
  v_eff_employment_type text;
  v_eff_plan_name       text;
  v_eff_fte             numeric;
  v_eff_location_id     uuid;
  v_eff_location_name   text;
  v_eff_start           date;
  v_using_fallback      boolean := false;

  v_headline       text;
  v_plain_english  text;
  v_plan_style     text;  -- 'wage' | 'contractor' | 'commission' | 'none'

  v_plan_label_friendly text;
  v_staff_display_name  text;
BEGIN
  -- 1. Auth + page access.
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  IF NOT (SELECT private.user_has_page_access('commission_guide', 'view')) THEN
    RAISE EXCEPTION 'not authorized to view the commission guide'
      USING ERRCODE = '42501';
  END IF;

  v_elevated := (SELECT private.user_has_elevated_access());

  SELECT a.staff_member_id
    INTO v_caller_staff
  FROM public.staff_member_user_access a
  WHERE a.user_id   = v_caller
    AND a.is_active = true
  LIMIT 1;

  v_target := COALESCE(p_staff_member_id, v_caller_staff);

  IF v_target IS NULL THEN
    RAISE EXCEPTION
      'no staff member id supplied and caller has no active staff mapping'
      USING ERRCODE = '22023';
  END IF;

  IF v_target IS DISTINCT FROM v_caller_staff AND NOT v_elevated THEN
    RAISE EXCEPTION
      'not authorized to view the commission guide for another staff member'
      USING ERRCODE = '42501';
  END IF;

  -- 2. Load staff row.
  SELECT sm.id, sm.full_name, sm.display_name, sm.is_active,
         sm.primary_role, sm.secondary_roles, sm.employment_type,
         sm.remuneration_plan, sm.fte, sm.primary_location_id
    INTO v_staff_row
  FROM public.staff_members sm
  WHERE sm.id = v_target;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'staff member not found: %', v_target
      USING ERRCODE = 'P0002';
  END IF;

  v_staff_display_name := COALESCE(
    NULLIF(btrim(v_staff_row.display_name), ''),
    NULLIF(btrim(v_staff_row.full_name), ''),
    'this staff member'
  );

  -- 3. Effective profile at v_as_of.
  SELECT *
    INTO v_profile
  FROM public.staff_profile_at(v_target, v_as_of)
  LIMIT 1;

  IF v_profile IS NULL OR v_profile.id IS NULL THEN
    v_using_fallback      := true;
    v_eff_role            := v_staff_row.primary_role;
    v_eff_secondary_roles := v_staff_row.secondary_roles;
    v_eff_employment_type := v_staff_row.employment_type;
    v_eff_plan_name       := v_staff_row.remuneration_plan;
    v_eff_fte             := v_staff_row.fte;
    v_eff_location_id     := v_staff_row.primary_location_id;
    v_eff_start           := NULL;
  ELSE
    v_eff_role            := v_profile.primary_role;
    v_eff_secondary_roles := v_profile.secondary_roles;
    v_eff_employment_type := v_profile.employment_type;
    v_eff_plan_name       := v_profile.remuneration_plan;
    v_eff_fte             := v_profile.fte;
    v_eff_location_id     := v_profile.primary_location_id;
    v_eff_start           := v_profile.effective_start_date;
  END IF;

  IF v_eff_location_id IS NOT NULL THEN
    SELECT l.name INTO v_eff_location_name
    FROM public.locations l
    WHERE l.id = v_eff_location_id;
  END IF;

  -- 4. Plan + rates map.
  SELECT p.id, p.plan_name, p.can_use_assistants,
         p.conditions_text, p.staff_on_this_plan_text, p.is_active,
         p.deduct_service_product_costs
    INTO v_plan
  FROM public.remuneration_plans p
  WHERE p.id = private.staff_plan_id_at(v_target, v_as_of)
  LIMIT 1;
  v_eff_plan_name := v_plan.plan_name;

  IF v_plan.id IS NOT NULL THEN
    SELECT COALESCE(
      jsonb_object_agg(r.commission_category, r.rate),
      '{}'::jsonb
    )
      INTO v_rates_map
    FROM public.remuneration_plan_rates r
    WHERE r.remuneration_plan_id = v_plan.id;
  END IF;

  v_rate_service      := NULLIF(v_rates_map ->> 'service',                  '')::numeric;
  v_rate_retail       := NULLIF(v_rates_map ->> 'retail_product',           '')::numeric;
  v_rate_professional := NULLIF(v_rates_map ->> 'professional_product',     '')::numeric;
  v_rate_toner        := NULLIF(v_rates_map ->> 'toner_with_other_service', '')::numeric;
  v_rate_ext_product  := NULLIF(v_rates_map ->> 'extensions_product',       '')::numeric;
  v_rate_ext_service  := NULLIF(v_rates_map ->> 'extensions_service',       '')::numeric;

  -- Treat 0 as "no rate" for eligibility decisions.
  IF v_rate_service      IS NOT NULL AND v_rate_service      <= 0 THEN v_rate_service      := NULL; END IF;
  IF v_rate_retail       IS NOT NULL AND v_rate_retail       <= 0 THEN v_rate_retail       := NULL; END IF;
  IF v_rate_professional IS NOT NULL AND v_rate_professional <= 0 THEN v_rate_professional := NULL; END IF;
  IF v_rate_toner        IS NOT NULL AND v_rate_toner        <= 0 THEN v_rate_toner        := NULL; END IF;
  IF v_rate_ext_product  IS NOT NULL AND v_rate_ext_product  <= 0 THEN v_rate_ext_product  := NULL; END IF;
  IF v_rate_ext_service  IS NOT NULL AND v_rate_ext_service  <= 0 THEN v_rate_ext_service  := NULL; END IF;

  v_plan_style := CASE
    WHEN v_eff_plan_name IS NULL THEN 'none'
    WHEN lower(coalesce(v_eff_employment_type, '')) = 'contractor'
      OR lower(coalesce(v_eff_plan_name, ''))      LIKE '%contractor%'
      THEN 'contractor'
    WHEN v_rate_service IS NULL
      OR lower(coalesce(v_eff_plan_name, ''))      LIKE '%wage%'
      THEN 'wage'
    ELSE 'commission'
  END;

  v_plan_label_friendly := COALESCE(v_eff_plan_name, 'current');

  -- ===========================================================================
  -- 5. Build a per-category map of real example sale lines.
  --    Prefer the selected staff in the last 90 days.
  --    Fall back to any staff in the last 365 days.
  -- ===========================================================================
  v_lookback_start := v_as_of - 90;
  v_fallback_start := v_as_of - 365;

  WITH staff_candidates AS (
    SELECT
      vc.commission_category_final AS cc,
      vc.product_service_name,
      vc.price_incl_gst,
      vc.price_ex_gst,
      vc.quantity,
      vc.raw_row_id,
      vc.location_id,
      vc.product_type_actual_derived,
      vc.sale_date,
      ROW_NUMBER() OVER (
        PARTITION BY vc.commission_category_final
        ORDER BY vc.sale_date DESC, vc.price_ex_gst DESC
      ) AS rn
    FROM public.v_commission_calculations_core vc
    WHERE vc.commission_category_final IN (
            'service','retail_product','professional_product',
            'toner_with_other_service','extensions_product','extensions_service'
          )
      AND vc.price_ex_gst IS NOT NULL
      AND vc.price_ex_gst > 0
      AND NULLIF(btrim(vc.product_service_name), '') IS NOT NULL
      AND vc.sale_date >= v_lookback_start
      AND vc.sale_date <= v_as_of
      AND (
        vc.staff_commission_id      = v_target
        OR vc.staff_work_id         = v_target
        OR vc.derived_staff_paid_id = v_target
      )
  ),
  staff_top AS (
    SELECT cc, product_service_name, price_incl_gst, price_ex_gst, quantity, raw_row_id, location_id, product_type_actual_derived
    FROM staff_candidates
    WHERE rn = 1
  ),
  fallback_candidates AS (
    SELECT
      vc.commission_category_final AS cc,
      vc.product_service_name,
      vc.price_incl_gst,
      vc.price_ex_gst,
      vc.quantity,
      vc.raw_row_id,
      vc.location_id,
      vc.product_type_actual_derived,
      COALESCE(
        NULLIF(btrim(vc.derived_staff_paid_display_name), ''),
        NULLIF(btrim(vc.work_display_name), ''),
        NULLIF(btrim(vc.commission_display_name), ''),
        'another staff member'
      ) AS source_staff,
      vc.sale_date,
      ROW_NUMBER() OVER (
        PARTITION BY vc.commission_category_final
        ORDER BY vc.sale_date DESC, vc.price_ex_gst DESC
      ) AS rn
    FROM public.v_commission_calculations_core vc
    WHERE vc.commission_category_final IN (
            'service','retail_product','professional_product',
            'toner_with_other_service','extensions_product','extensions_service'
          )
      AND vc.price_ex_gst IS NOT NULL
      AND vc.price_ex_gst > 0
      AND NULLIF(btrim(vc.product_service_name), '') IS NOT NULL
      AND vc.sale_date >= v_fallback_start
      AND vc.sale_date <= v_as_of
  ),
  fallback_top AS (
    SELECT cc, product_service_name, price_incl_gst, price_ex_gst, quantity, raw_row_id, location_id, product_type_actual_derived, source_staff
    FROM fallback_candidates
    WHERE rn = 1
  ),
  picked AS (
    SELECT
      cc,
      jsonb_build_object(
        'product_service_name',      product_service_name,
        'price_incl_gst',            price_incl_gst,
        'price_ex_gst',              price_ex_gst,
        'quantity',                  quantity,
        'source_raw_row_id',         raw_row_id,
        'source_location_id',        location_id,
        'source_product_type',       product_type_actual_derived,
        'is_staff_specific',         TRUE,
        'source_staff_display_name', v_staff_display_name
      ) AS ex
    FROM staff_top
    UNION ALL
    SELECT
      ft.cc,
      jsonb_build_object(
        'product_service_name',      ft.product_service_name,
        'price_incl_gst',            ft.price_incl_gst,
        'price_ex_gst',              ft.price_ex_gst,
        'quantity',                  ft.quantity,
        'source_raw_row_id',         ft.raw_row_id,
        'source_location_id',        ft.location_id,
        'source_product_type',       ft.product_type_actual_derived,
        'is_staff_specific',         FALSE,
        'source_staff_display_name', ft.source_staff
      ) AS ex
    FROM fallback_top ft
    WHERE NOT EXISTS (
      SELECT 1 FROM staff_top st WHERE st.cc = ft.cc
    )
  )
  SELECT COALESCE(jsonb_object_agg(cc, ex), '{}'::jsonb)
    INTO v_examples_map
  FROM picked;

  -- ===========================================================================
  -- 6. Eligible for commission (compact format, real example).
  --    Labels match the redesign spec exactly.
  -- ===========================================================================

  IF v_rate_service IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'service',
      'label',    'Salon Services',
      'rate',     v_rate_service,
      'summary',  'Salon services on this plan.',
      'example',  CASE
        WHEN v_examples_map -> 'service' IS NULL THEN NULL
        ELSE (v_examples_map -> 'service') || jsonb_build_object(
          'rate',       v_rate_service,
          'commission', round(((v_examples_map -> 'service' ->> 'price_ex_gst')::numeric) * v_rate_service, 2)
        )
      END
    ))::jsonb;
  END IF;

  IF v_rate_retail IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'retail_product',
      'label',    'Retail Products',
      'rate',     v_rate_retail,
      'summary',  'Eligible take-home retail products.',
      'example',  CASE
        WHEN v_examples_map -> 'retail_product' IS NULL THEN NULL
        ELSE (v_examples_map -> 'retail_product') || jsonb_build_object(
          'rate',       v_rate_retail,
          'commission', round(((v_examples_map -> 'retail_product' ->> 'price_ex_gst')::numeric) * v_rate_retail, 2)
        )
      END
    ))::jsonb;
  END IF;

  IF v_rate_professional IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'professional_product',
      'label',    'Treatment Products',
      'rate',     v_rate_professional,
      'summary',  'Treatment / professional product lines.',
      'example',  CASE
        WHEN v_examples_map -> 'professional_product' IS NULL THEN NULL
        ELSE (v_examples_map -> 'professional_product') || jsonb_build_object(
          'rate',       v_rate_professional,
          'commission', round(((v_examples_map -> 'professional_product' ->> 'price_ex_gst')::numeric) * v_rate_professional, 2)
        )
      END
    ))::jsonb;
  END IF;

  IF v_rate_toner IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'toner_with_other_service',
      'label',    'Toner Lines',
      'rate',     v_rate_toner,
      'summary',  'Toner added to another service.',
      'example',  CASE
        WHEN v_examples_map -> 'toner_with_other_service' IS NULL THEN NULL
        ELSE (v_examples_map -> 'toner_with_other_service') || jsonb_build_object(
          'rate',       v_rate_toner,
          'commission', round(((v_examples_map -> 'toner_with_other_service' ->> 'price_ex_gst')::numeric) * v_rate_toner, 2)
        )
      END
    ))::jsonb;
  END IF;

  IF v_rate_ext_product IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'extensions_product',
      'label',    'Extension Products',
      'rate',     v_rate_ext_product,
      'summary',  'Extension hair or bond product.',
      'example',  CASE
        WHEN v_examples_map -> 'extensions_product' IS NULL THEN NULL
        ELSE (v_examples_map -> 'extensions_product') || jsonb_build_object(
          'rate',       v_rate_ext_product,
          'commission', round(((v_examples_map -> 'extensions_product' ->> 'price_ex_gst')::numeric) * v_rate_ext_product, 2)
        )
      END
    ))::jsonb;
  END IF;

  IF v_rate_ext_service IS NOT NULL THEN
    v_eligible_sections := v_eligible_sections || jsonb_build_array(jsonb_build_object(
      'category', 'extensions_service',
      'label',    'Extension Labour',
      'rate',     v_rate_ext_service,
      'summary',  'Extension install / removal / maintenance labour.',
      'example',  CASE
        WHEN v_examples_map -> 'extensions_service' IS NULL THEN NULL
        ELSE (v_examples_map -> 'extensions_service') || jsonb_build_object(
          'rate',       v_rate_ext_service,
          'commission', round(((v_examples_map -> 'extensions_service' ->> 'price_ex_gst')::numeric) * v_rate_ext_service, 2)
        )
      END
    ))::jsonb;
  END IF;

  -- ===========================================================================
  -- 7. Plan summary and date-aware service-cost example basis.
  -- ===========================================================================
  -- A guide is an illustration under the selected plan/cost as at the guide
  -- date, retaining the real source line price and quantity. It must not reuse
  -- the original seller's commission or guess a zero when a cost is missing.
  FOR v_section IN SELECT value FROM jsonb_array_elements(v_eligible_sections)
  LOOP
    v_example := v_section -> 'example';
    IF jsonb_typeof(v_example) = 'object' THEN
      SELECT * INTO v_basis
      FROM private.service_commission_basis(
        private.service_id_for_sale(
          (v_example ->> 'source_raw_row_id')::uuid,
          (v_example ->> 'source_location_id')::uuid,
          v_example ->> 'product_service_name'),
        v_as_of,
        (v_example ->> 'price_ex_gst')::numeric,
        (v_example ->> 'quantity')::numeric,
        coalesce(v_plan.deduct_service_product_costs, false), false,
        coalesce(v_example ->> 'source_product_type', '') = 'Service', true
      );
      v_example := v_example || jsonb_build_object(
        'product_cost_ex_gst', v_basis.actual_product_cost_ex_gst,
        'commissionable_ex_gst', v_basis.actual_commissionable_ex_gst,
        'service_cost_status', v_basis.service_cost_status,
        'example_basis_date', v_as_of,
        'commission', CASE WHEN v_basis.service_cost_status IN ('ready','not_required')
          THEN round(v_basis.actual_commissionable_ex_gst * (v_section ->> 'rate')::numeric, 2)
          ELSE NULL END,
        'calculation_note', CASE WHEN v_basis.service_cost_status IN ('ready','not_required')
          THEN 'Illustration using the plan and product cost effective on the guide date.'
          ELSE 'Commission awaiting product costs or source-data review. An admin must resolve the service cost and quantity before an example can be calculated.' END
      );
      v_section := v_section || jsonb_build_object('example', v_example);
    END IF;
    v_adjusted_sections := v_adjusted_sections || jsonb_build_array(v_section);
  END LOOP;
  v_eligible_sections := v_adjusted_sections;

  v_headline := CASE
    WHEN v_eff_role IS NOT NULL AND v_eff_plan_name IS NOT NULL
      THEN v_eff_role || ' on the ' || v_eff_plan_name || ' plan'
    WHEN v_eff_plan_name IS NOT NULL
      THEN v_eff_plan_name || ' plan'
    WHEN v_eff_role IS NOT NULL
      THEN v_eff_role
    ELSE 'Your commission setup'
  END;

  v_plain_english := CASE v_plan_style
    WHEN 'none' THEN
      'You are not currently on a remuneration plan. If this looks wrong, please speak to your manager.'
    WHEN 'wage' THEN
      'You are on the ' || v_eff_plan_name
        || ' plan. You are paid hourly for salon service work. You may also earn commission on eligible retail products.'
    WHEN 'contractor' THEN
      'You are on the ' || v_eff_plan_name
        || ' plan. Eligible services are paid at your contractor service rate. Some product and special categories may use different rates.'
    ELSE
      'You are on the ' || v_eff_plan_name
        || ' plan. You can earn commission on eligible services, retail products, treatment products, toners, and extension items, depending on how each sale is treated.'
  END;

  IF coalesce(v_plan.deduct_service_product_costs, false) THEN
    v_plain_english := v_plain_english || ' For service sales, the product cost per unit is deducted from the sale amount excluding GST before applying commission. Discounts reduce the sale amount but not the cost. Commission on a positive sale cannot fall below zero. Credits use signed credit-date rules and exceptional refunds require review.';
  END IF;

  v_notes := jsonb_build_array(
    jsonb_build_object(
      'heading', 'Vouchers',
      'body',
        'Selling a voucher does not earn commission because it is a prepayment. When the voucher is later used, the actual service or product is treated normally.'
    )
  );

  v_summary := jsonb_build_object(
    'headline',         v_headline,
    'plain_english',    v_plain_english,
    'important_notes',  v_notes,
    'plan_style',       v_plan_style,
    'using_fallback_to_current_profile', v_using_fallback
  );

  -- ===========================================================================
  -- 8. Legacy rate cards (kept for back-compat; staff page no longer uses).
  -- ===========================================================================
  v_rate_cards := jsonb_build_array(
    jsonb_build_object(
      'label',    'Salon Services',
      'category', 'service',
      'rate',     v_rate_service,
      'has_rate', v_rate_service IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_service IS NULL
          THEN 'No service commission on this plan.'
          ELSE 'You earn this rate on eligible salon services.'
        END
    ),
    jsonb_build_object(
      'label',    'Retail Products',
      'category', 'retail_product',
      'rate',     v_rate_retail,
      'has_rate', v_rate_retail IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_retail IS NULL
          THEN 'No retail commission on this plan.'
          ELSE 'You earn this rate on eligible take-home retail products.'
        END
    ),
    jsonb_build_object(
      'label',    'Treatment Products',
      'category', 'professional_product',
      'rate',     v_rate_professional,
      'has_rate', v_rate_professional IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_professional IS NULL
          THEN 'No treatment / professional product commission on this plan.'
          ELSE 'You earn this rate on treatment / professional products.'
        END
    ),
    jsonb_build_object(
      'label',    'Toner Lines',
      'category', 'toner_with_other_service',
      'rate',     v_rate_toner,
      'has_rate', v_rate_toner IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_toner IS NULL
          THEN 'No toner-line commission on this plan.'
          ELSE 'You earn this rate on toner added to another service.'
        END
    ),
    jsonb_build_object(
      'label',    'Extension Products',
      'category', 'extensions_product',
      'rate',     v_rate_ext_product,
      'has_rate', v_rate_ext_product IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_ext_product IS NULL
          THEN 'No extension product commission on this plan.'
          ELSE 'You earn this rate on extension hair or bonded product.'
        END
    ),
    jsonb_build_object(
      'label',    'Extension Labour',
      'category', 'extensions_service',
      'rate',     v_rate_ext_service,
      'has_rate', v_rate_ext_service IS NOT NULL,
      'plain_english',
        CASE WHEN v_rate_ext_service IS NULL
          THEN 'No extension labour commission on this plan.'
          ELSE 'You earn this rate on extension install / removal / maintenance.'
        END
    )
  );

  -- ===========================================================================
  -- 9. Full product classification (legacy table + admin-only view).
  -- ===========================================================================
  WITH derived AS (
    SELECT
      pm.product_description AS name,
      pm.system_type,
      pm.product_type,
      CASE
        WHEN lower(btrim(coalesce(pm.product_description, ''))) = 'green fee'
          THEN 'no_commission_greenfee'
        WHEN lower(btrim(coalesce(pm.product_description, ''))) = 'redo'
          THEN 'no_commission_redo'
        WHEN lower(btrim(coalesce(pm.product_description, ''))) = 'training product'
          THEN 'no_commission_trainingproduct'
        WHEN lower(btrim(coalesce(pm.product_description, ''))) = 'miscellaneous'
          THEN 'no_commission_miscellaneousproduct'
        WHEN lower(btrim(coalesce(pm.product_description, ''))) = 'coffee'
          THEN 'no_commission_miscellaneousproduct'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'voucher'
          THEN 'no_commission_voucher'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'unclassified'
          THEN 'no_commission_unclassified'
        WHEN right(btrim(coalesce(pm.product_description, '')), 1) = '*'
          THEN 'professional_product'
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = 'professional product'
          THEN 'professional_product'
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = 'retail product'
          THEN 'retail_product'
        WHEN lower(btrim(coalesce(pm.product_type, ''))) = '-'
          THEN 'no_commission_unclassified'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'service'
          THEN 'service'
        WHEN lower(btrim(coalesce(pm.system_type, ''))) = 'retail'
          THEN 'retail_product'
        ELSE NULL
      END AS commission_category
    FROM public.product_master pm
    WHERE pm.is_active = true
  )
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'product_or_category',     d.name,
      'imported_type',           d.system_type,
      'configured_system_type',  d.system_type,
      'configured_product_type', d.product_type,
      'commission_category',     d.commission_category,
      'rate_for_this_plan',
        CASE
          WHEN d.commission_category IS NULL THEN NULL
          ELSE NULLIF(v_rates_map ->> d.commission_category, '')::numeric
        END,
      'counts_for_commission',
        d.commission_category IN (
          'service','retail_product','professional_product',
          'toner_with_other_service','extensions_product','extensions_service'
        ),
      'plain_english',
        CASE d.commission_category
          WHEN 'professional_product' THEN
            CASE
              WHEN right(btrim(coalesce(d.name, '')), 1) = '*'
                THEN 'Treated as a treatment product (the trailing * tags it that way).'
              ELSE 'Configured as a treatment product.'
            END
          WHEN 'service'        THEN 'Treated as a salon service.'
          WHEN 'retail_product' THEN 'Treated as a take-home retail product.'
          WHEN 'no_commission_voucher' THEN
            'Voucher sales are prepayments, so no commission is paid when the voucher is sold.'
          WHEN 'no_commission_greenfee' THEN
            'Green fees are not staff service sales, so no commission is paid.'
          WHEN 'no_commission_redo' THEN
            'Redo / rework lines are not treated as new commissionable sales.'
          WHEN 'no_commission_trainingproduct' THEN
            'Training items are excluded from commission.'
          WHEN 'no_commission_miscellaneousproduct' THEN
            CASE WHEN lower(btrim(coalesce(d.name, ''))) = 'coffee'
              THEN 'Coffee is not treated as a hair service or retail product.'
              ELSE 'Not treated as a hair service or retail product.'
            END
          WHEN 'no_commission_unclassified' THEN
            'Miscellaneous line item not loaded as a product or service in the system.'
          ELSE 'Not currently mapped to a commission category.'
        END
    )
    ORDER BY d.name
  ), '[]'::jsonb)
    INTO v_classification
  FROM derived d;

  IF v_elevated THEN
    v_admin_full_guide := v_classification;
  ELSE
    v_admin_full_guide := '[]'::jsonb;
  END IF;

  -- ===========================================================================
  -- 10. Legacy fields kept on the envelope so older clients still parse.
  --     The redesigned page does not render any of these.
  -- ===========================================================================
  RETURN jsonb_build_object(
    'as_of_date', v_as_of,
    'staff', jsonb_build_object(
      'staff_member_id',        v_staff_row.id,
      'display_name',           v_staff_row.display_name,
      'full_name',              v_staff_row.full_name,
      'is_active',              v_staff_row.is_active,
      'primary_role',           v_eff_role,
      'secondary_roles',        v_eff_secondary_roles,
      'employment_type',        v_eff_employment_type,
      'fte',                    v_eff_fte,
      'primary_location_id',    v_eff_location_id,
      'primary_location_name',  v_eff_location_name,
      'remuneration_plan',      v_eff_plan_name,
      'effective_start_date',   v_eff_start
    ),
    'plan', CASE
      WHEN v_plan.id IS NULL THEN NULL
      ELSE jsonb_build_object(
        'id',                       v_plan.id,
        'plan_name',                v_plan.plan_name,
        'can_use_assistants',       v_plan.can_use_assistants,
        'conditions_text',          v_plan.conditions_text,
        'staff_on_this_plan_text',  v_plan.staff_on_this_plan_text,
        'is_active',                v_plan.is_active,
        'deduct_service_product_costs', coalesce(v_plan.deduct_service_product_costs, false),
        'rates',                    v_rates_map
      )
    END,
    'plan_summary',          v_summary,

    -- New personalised sections (used by the redesigned staff page).
    'eligible_sections',     v_eligible_sections,
    'not_eligible_sections', v_not_eligible_sections, -- empty; the page renders a static list instead
    'recent_items_to_be_aware_of', v_recent_items,    -- empty; the page does not render this section
    'recent_lookback_days',  90,
    'admin_full_product_guide',    v_admin_full_guide,

    -- Legacy fields (kept for backwards compatibility).
    'rate_cards',            v_rate_cards,
    'classification_table',  v_classification,
    'exclusions',            '[]'::jsonb,
    'special_cases',         '[]'::jsonb,
    'examples',              '[]'::jsonb,

    'caller', jsonb_build_object(
      'is_elevated', v_elevated,
      'is_self',     v_target IS NOT DISTINCT FROM v_caller_staff
    )
  );
END;
$function$;


-- Manual names are catalogue references only; none of these inserts creates a cost.
DO $$ DECLARE n text; sid uuid; BEGIN FOR n IN SELECT jsonb_array_elements_text($names$["Capacity","Patch Test","zOLD Fringe Trim","zOLD Directors Mens CBW","zOLD Senior Mens CBW","zOLD Master Mens CBW","zOLD Blow Wave Service","zOLD Quickie","zOLD Bleach Retouch","zOLD Balayage Full","zOLD Balayage Partial 2","zOLD Balayage Partial 1","zOLD Balayage Half","zOLD Balayage Full Extra","Consultation","Extensions Consultation","Cezanne Smoothing Consultation","BKT Nanoplasty Consultation","Grey Specialist Consultation","zOLD Toner","zOLD City Beats Remover","zOLD Permanent","zOLD T-Section","zOLD Double Toner (10-20g)*","zOLD Toner Check","zOLD Colourcombo","zOLD Colour Retouch","zOLD Partial Foils 2","zOLD Full Head Foils","zOLD Full Head Foils Extra","zOLD Half Head Foils","zOLD Partial Foils 1","zOLD Individual Foils","zOLD WH Full Head","zOLD WH Full Head Extra","zOLD WH Partial 1","zOLD WH Partial 2","zOLD WH Half Head","ABC Treatment*","Cat Treatment (x6)*","Cat + Shot Phix Treatment*","Shot Phix Double (x6)*","Cat Treatment Double*","Shot Phix Single (x3)*","Metal Detox Treatment*","Malibu C Colour Pigment Removal*","K18 Standard Treatment*","K18 Luxury Treatment*","Malibu C*","K18 Standard Treatment with Cut*","K18 Metal Removal*","Iles Standard Treatment*","Iles Luxury Treatment*","Acidic Color Gloss 1 Min Mask Treatment*","zOLD Hair Extension Application Tape","zOLD Hair Extension Removal Tape","zOLD Extensions Refit Microweft (less then 6weeks)","zOLD Wedding Trial","zOLD Hair-Up","zOLD Wedding Hair-Up","zOLD Extensions Refit Microweft (more than 6weeks)","Cut and Blow Wave Emerging Stylist","Cut and Blow Wave Master Stylist","Cut and Blow Wave Senior Stylist","Cut and Blow Wave Director Stylist","Fringe Trim Regular","Fringe Trim Casual","Cut and Blow Wave Director Mens 30min","Cut and Blow Wave Master Mens 30mins","Cut and Blow Wave Creative Director","Apprentice Solid Form","zOLD Apprentice Solid Form with other service","Cut and Blow Wave Director Stylist Orewa","Curly/Wavy Cut First Visit","Curly/Wavy Cut Maintenance","Cut with Colour Emerging Stylist","Cut with Colour Senior Stylist","Cut with Colour Director Stylist","Cut with Colour Master Stylist","Cut with Colour Creative Director","Extensions (tapes individual piece x2) Install","Extensions (tapes 20 pieces) Install","Extensions (tapes 40 pieces) Install","Extensions (tapes 60 pieces) Install","Extensions (tapes individual piece x2) Maintenance","Extensions (tapes 20 pieces) Maintenance","Extensions (tapes 40 pieces) Maintenance","Extensions (tapes 60 pieces) Maintenance","Extensions (tapes individual piece x2) Removal","Extensions (tapes 20 pieces) Removal","Extensions (tapes 40 pieces) Removal","Extensions (tapes 60 pieces) Removal","Extensions (wefts half head microbead) Install","Extensions (wefts full head microbead) Install","Extensions (wefts microbead) Maintenance (per row)","Extensions (wefts sew-in) Maintenance (per row)","Bonded extension hair prep 45mins","Bonded extension hair prep 60mins","Bonded extension hair prep 75mins","Bonded extension install 40 bonds","Bonded extension install 80 bonds","Bonded extension install 120 bonds","Bonded extension removal 30mins","Bonded extension removal 60mins","Bonded extension install individual","Extensions (tapes 10 pieces) Maintenance","Extensions blow wave","Extensions (wefts 3/4 head microbead) Install","Extensions weft Removal (per row)","Extensions (wefts 3/4 head sew-in) Install","Extensions (wefts full head sew-in) Install","Extensions (wefts half head sew-in) Install","Complimentary Blow Wave","Style Lesson Senior","Style Check","Blow Wave Service (above shoulders) Emerging","Blow Wave Service (above shoulders) Senior","Blow Wave Service (below shoulders) Emerging","Blow Wave Service (below shoulders) Senior","Dry Style/Hot Tool Style","Hair-Up Emerging","Hair-Up Senior","Hair-Up Director","Hair-Up Master","Preferred Stylist Blow Wave","Style Lesson Creative Director","Blow Wave Service Creative Director","Hair Tinsel Install","Extra Product (15g) / Extra Time (10m)","Individual Foils with a Colour Service","Individual Foils (up to 10) with no Colour Service","Extra time hair up Emerging Stylist","Extra Time Hair Up Senior Stylist","Extra Time Hair Up Director Stylist","Extra Time Hair Up Master Stylist","Forfeited Deposit","Tip Out Surcharge","Cezanne Application","Cezanne Smoothing","Additional Cezanne 10g","BKT Nanoplasty Application","BKT Nanoplasty Smoothing","Additional BKT 10g","Green fee","Frog","Notes","Lunch","Unavailable","Drinks","Training","Helping Out","Meeting","Desk","REDO","Rubbish out","Rubbish in","Recycling In","Recycling out","Leadership","School Hols","Long Weekend","Monthly floor tasks","Off job training","Content Creation","Hold for client","Set Up","Lunch DON'T MOVE","Call new client","Training possible - TBC","Model for training","Notes for receptionist","Mop Floors","Clean windows","Sharking","Empty & clean aircon filter/drain","Styled by you","Shopping","End Of Day Tasks","Restocking the salon","Bleach Bath","Bleach Root Retouch Emerging Colourist","All-Over Toner with Other Service (20-39g)*","All-Over Toner Maintenance Service (20-39g)","Global Bleach Emerging Colourist","Fashion Colour Over Bleach","All-Over Toner with Other Service (<20g)*","All-Over Toner Maintenance Service (<20g)","Colour Root Retouch Emerging Colourist","Global Colour Emerging Colourist","zOLD Foils (Partial) Emerging Colourist","Foils (Partial/Face Frame) Emerging Colourist","Foils (Half Head) Emerging Colourist","Foils (Full Head) Emerging Colourist","Foils (Full Head Extra) Emerging Colourist","T-Section Emerging Colourist","Colour Combo Emerging Stylist","zOLD T-Section maintenance with a cut","Express Clear Gloss and Blow Wave","zOLD T-Section Express with Apprentice","zOLD Colour Root Retouch Express with Apprentice","Basin Balayage","Toner Check","All-Over Toner with Other Service (40-60g)*","All-Over Toner Maintenance Service (40-60)g","Training Product - Foils/balayage","Express Clear Gloss (with a cut)","Training Product - Toner/Colour","Dimensional Toner Maintenance Service (<20g)","Dimensional Toner Maintenance Service (20-39g)","Dimensional Toner Maintenance Service (40-60)g","Dimensional Toner with Other Service (<20g)*","Dimensional Toner with Other Service (20-39g)*","Dimensional Toner with Other Service (40-60g)*","Balayage/Hair Painting (Full) Senior Colourist","Balayage/Hair Painting (Full Extra) Senior Colourist","Balayage/Hair Painting (Half) Senior Colourist","z OLD Balayage/Hair Painting (Partial) Senior Colourist","Balayage/Hair Painting (Partial/Face Frame) Senior Colourist","Bleach Root Retouch Senior Colourist","Global Bleach Senior Colourist","Colour Root Retouch Senior Colourist","Global Colour Senior Colourist","zOLD Foils (Partial) Senior Colourist","Foils (Partial/Face Frame) Senior Colourist","Foils (Half Head) Senior Colourist","Foils (Full Head) Senior Colourist","Foils (Full Head Extra) Senior Colourist","Colour Combo Senior Colourist","T-Section Senior Colourist","Balayage/Hair Painting (Full) Master Colourist","Balayage/Hair Painting (Full Extra) Master Colourist","Balayage/Hair Painting (Half) Master Colourist","zOLD Balayage/Hair Painting (Partial) Master Colourist","Balayage/Hair Painting (Partial/Face Frame) Master Colourist","Bleach Root Retouch Master Colourist","Global Bleach Master Colourist","Colour Root Retouch Master Colourist","Global Colour Master Colourist","zOLD Foils (Partial) Master Colourist","Foils (Partial/Face Frame) Master Colourist","Foils (Half Head) Master Colourist","Foils (Full Head) Master Colourist","Foils (Full Head Extra) Master Colourist","Colour Combo Master Colourist","T-Section Master Colourist"]$names$::jsonb) LOOP
 IF NOT EXISTS(SELECT 1 FROM public.service_product_cost_aliases WHERE description_key=lower(btrim(n))) THEN
 INSERT INTO public.service_product_cost_services(service_name,is_active) VALUES(n,NOT (n ~* '^z ?old')) RETURNING id INTO sid;
 INSERT INTO public.service_product_cost_aliases VALUES(lower(btrim(n)),sid); ELSE
 UPDATE public.service_product_cost_services SET is_active=true WHERE id=(SELECT service_id FROM public.service_product_cost_aliases WHERE description_key=lower(btrim(n))) AND NOT (n ~* '^z ?old');
 END IF; END LOOP; END $$;

-- New private helpers are callable only within authenticated application queries.
DO $$ DECLARE f regprocedure; BEGIN FOR f IN SELECT p.oid::regprocedure FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='private' AND p.proname IN ('service_id_for_sale','service_commission_basis','require_ready_commission','require_service_cost_access','discover_service_product_costs','discover_service_after_import') LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon',f); EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',f); END LOOP; END $$;
NOTIFY pgrst,'reload schema';
COMMIT;