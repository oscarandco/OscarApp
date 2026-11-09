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
