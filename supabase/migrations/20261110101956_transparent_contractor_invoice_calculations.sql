ALTER TABLE public.contractor_invoices ADD COLUMN rounding_adjustment_ex_gst numeric(12,2) NOT NULL DEFAULT 0;
ALTER TABLE public.contractor_invoices ADD COLUMN calculation_version integer NOT NULL DEFAULT 1;
CREATE FUNCTION private.contractor_source_invoice_calculation(p_invoice text,p_location_id uuid,p_sale_date date,p_staff_member_id uuid) RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET jit=off AS $$
DECLARE result jsonb;
BEGIN
 IF auth.uid() IS NULL OR NOT private.user_has_page_access('contractor_invoices','view') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='42501'; END IF;
 WITH selected AS MATERIALIZED (
  SELECT l.*,coalesce(l.resolved_derived_staff_paid_id,l.derived_staff_paid_id)=p_staff_member_id AND l.payroll_status='payable' AS eligible
  FROM public.v_admin_payroll_lines_weekly l
  WHERE l.invoice=p_invoice AND (p_location_id IS NULL OR l.location_id=p_location_id) AND (p_sale_date IS NULL OR l.sale_date=p_sale_date)
 ), detail AS (
  SELECT l.id,l.sale_date,l.sale_datetime,l.customer_name,l.product_service_name,l.product_type_actual,l.price_ex_gst,
   coalesce(nullif(trim(l.derived_staff_paid_display_name),''),nullif(trim(l.staff_paid_name_derived),''),'Unassigned') owner_name,
   coalesce(nullif(trim(l.work_display_name),''),nullif(trim(l.work_full_name),''),nullif(trim(l.staff_work_name),''),'Unassigned') worker_name,
   coalesce(l.eligible,false) eligible,
   CASE WHEN l.eligible THEN l.actual_product_cost_ex_gst ELSE 0 END product_cost_ex_gst,
   CASE WHEN l.eligible THEN l.actual_commissionable_ex_gst ELSE 0 END commissionable_ex_gst,
   CASE WHEN l.eligible THEN l.actual_commission_rate ELSE NULL END commission_rate,
   CASE WHEN l.eligible THEN l.actual_commission_amt_ex_gst ELSE 0 END contractor_fee_ex_gst
  FROM selected l
 ) SELECT jsonb_build_object('calculation_version',2,
  'lines',coalesce(jsonb_agg(to_jsonb(d) ORDER BY d.sale_datetime NULLS LAST,d.price_ex_gst DESC NULLS LAST,d.id),'[]'::jsonb),
  'customer_total_ex_gst',round(coalesce(sum(d.price_ex_gst),0),2),
  'eligible_sales_ex_gst',round(coalesce(sum(d.price_ex_gst) FILTER(WHERE d.eligible),0),2),
  'product_cost_ex_gst',round(coalesce(sum(d.product_cost_ex_gst),0),2),
  'commissionable_ex_gst',round(coalesce(sum(d.commissionable_ex_gst),0),2),
  'contractor_fee_ex_gst',round(coalesce(sum(d.contractor_fee_ex_gst),0),2)) INTO result FROM detail d;
 RETURN result;
END $$;
CREATE FUNCTION public.get_contractor_source_invoice_calculation(p_invoice text,p_location_id uuid,p_sale_date date,p_staff_member_id uuid) RETURNS jsonb
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT private.contractor_source_invoice_calculation(p_invoice,p_location_id,p_sale_date,p_staff_member_id); $$;

CREATE FUNCTION private.contractor_invoice_preview_v2(p_pay_week_start date,p_staff_member_id uuid) RETURNS TABLE(staff_member_id uuid,pay_week_start date,pay_week_end date,source_invoice_number text,sale_date date,customer_name text,location_id uuid,location_name text,client_invoice_amount_ex_gst numeric,contractor_amount_ex_gst numeric,commission_percentage numeric,product_cost_ex_gst numeric,commissionable_ex_gst numeric,payroll_subtotal_ex_gst numeric,applied_rates jsonb)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path='' SET jit=off AS $$
BEGIN
 IF auth.uid() IS NULL OR NOT private.user_has_page_access('contractor_invoices','view') THEN RAISE EXCEPTION 'Forbidden' USING ERRCODE='42501'; END IF;
 RETURN QUERY WITH selected AS MATERIALIZED (
  SELECT l.* FROM public.v_admin_payroll_lines_weekly l WHERE l.pay_week_start=p_pay_week_start AND l.payroll_status='payable'
   AND coalesce(l.resolved_derived_staff_paid_id,l.derived_staff_paid_id)=p_staff_member_id AND l.invoice IS NOT NULL
 ), grouped AS (
  SELECT l.invoice, min(l.sale_date) sale_date,min(l.customer_name) customer_name,
   (array_agg(l.location_id ORDER BY l.location_name NULLS LAST))[1] location_id,min(l.location_name) location_name,
   round(sum(coalesce(l.price_ex_gst,0)),2) sale,round(sum(coalesce(l.actual_commission_amt_ex_gst,0)),2) fee,
   sum(coalesce(l.actual_commission_amt_ex_gst,0)) raw_fee,round(sum(coalesce(l.actual_product_cost_ex_gst,0)),2) cost,
   round(sum(coalesce(l.actual_commissionable_ex_gst,0)),2) basis,
   jsonb_agg(DISTINCT jsonb_build_object('type',l.product_type_actual,'rate',l.actual_commission_rate)) rates
  FROM selected l GROUP BY l.invoice
 ) SELECT p_staff_member_id,p_pay_week_start,p_pay_week_start+6,g.invoice,g.sale_date,g.customer_name,g.location_id,g.location_name,g.sale,g.fee,
  CASE WHEN g.sale>0 THEN round(g.fee/g.sale,6) END,g.cost,g.basis,round(sum(g.raw_fee) OVER(),2),g.rates
 FROM grouped g ORDER BY g.sale_date NULLS LAST,g.invoice;
END $$;
CREATE FUNCTION public.get_contractor_invoice_preview_v2(p_pay_week_start date,p_staff_member_id uuid) RETURNS TABLE(staff_member_id uuid,pay_week_start date,pay_week_end date,source_invoice_number text,sale_date date,customer_name text,location_id uuid,location_name text,client_invoice_amount_ex_gst numeric,contractor_amount_ex_gst numeric,commission_percentage numeric,product_cost_ex_gst numeric,commissionable_ex_gst numeric,payroll_subtotal_ex_gst numeric,applied_rates jsonb)
LANGUAGE sql STABLE SECURITY INVOKER SET search_path='' AS $$ SELECT * FROM private.contractor_invoice_preview_v2(p_pay_week_start,p_staff_member_id); $$;

CREATE OR REPLACE FUNCTION private.create_contractor_invoice_v2(p_pay_week_start date, p_staff_member_id uuid, p_internal_note text DEFAULT NULL::text, p_replaces_invoice_id uuid DEFAULT NULL::uuid, p_force_revision_number integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
 SET jit TO 'off'
AS $function$
DECLARE
  v_week_end date;
  v_invoice_date date := (now() AT TIME ZONE 'Pacific/Auckland')::date;
  v_source_generated_at timestamptz := now();
  v_invoice_id uuid := gen_random_uuid();
  v_subtotal numeric := 0;
  v_rounding_adjustment numeric := 0;
  v_gst numeric := 0;
  v_total numeric := 0;
  v_line_count integer := 0;
  v_base_invoice_number text;
  v_invoice_number text;
  v_revision_number integer := COALESCE(p_force_revision_number, 0);
  v_contractor record;
  v_buyer record;
  v_gst_display text;
  v_invoice_code text;
  v_missing text[];
  v_buyer_missing text[];
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT private.user_has_page_access('contractor_invoices', 'full') THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_pay_week_start IS NULL OR p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'p_pay_week_start and p_staff_member_id are required';
  END IF;

  v_week_end := (p_pay_week_start + interval '6 days')::date;

  SELECT
    s.id, s.full_name, s.display_name, s.employment_type,
    s.contractor_invoice_name, s.contractor_company_name, s.contractor_invoice_code,
    s.contractor_email, s.contractor_gst_registered, s.contractor_ird_number,
    s.contractor_street_address, s.contractor_suburb, s.contractor_city_postcode,
    s.primary_location_id
  INTO v_contractor
  FROM public.staff_members s
  WHERE s.id = p_staff_member_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Contractor not found' USING ERRCODE = 'P0002';
  END IF;

  IF lower(coalesce(v_contractor.employment_type, '')) <> 'contractor' THEN
    RAISE EXCEPTION 'Staff member is not configured as a contractor';
  END IF;

  -- Contractor setup completeness.
  -- contractor_invoice_name is no longer required: the printed invoice
  -- uses staff_members.full_name as the person name.
  v_missing := ARRAY[]::text[];
  v_invoice_code := NULLIF(trim(coalesce(v_contractor.contractor_invoice_code, '')), '');
  IF v_invoice_code IS NULL THEN v_missing := v_missing || 'contractor_invoice_code'; END IF;
  IF v_contractor.contractor_gst_registered IS NULL THEN v_missing := v_missing || 'contractor_gst_registered'; END IF;
  IF NULLIF(trim(coalesce(v_contractor.contractor_street_address, '')), '') IS NULL THEN v_missing := v_missing || 'contractor_street_address'; END IF;
  IF NULLIF(trim(coalesce(v_contractor.contractor_suburb, '')), '') IS NULL THEN v_missing := v_missing || 'contractor_suburb'; END IF;
  IF NULLIF(trim(coalesce(v_contractor.contractor_city_postcode, '')), '') IS NULL THEN v_missing := v_missing || 'contractor_city_postcode'; END IF;
  IF v_contractor.contractor_gst_registered IS TRUE
     AND NULLIF(trim(coalesce(v_contractor.contractor_ird_number, '')), '') IS NULL THEN
    v_missing := v_missing || 'contractor_ird_number';
  END IF;

  IF array_length(v_missing, 1) > 0 THEN
    RAISE EXCEPTION 'Contractor setup incomplete: %', array_to_string(v_missing, ', ');
  END IF;

  -- Business settings completeness.
  SELECT
    b.legal_business_name, b.trading_name, b.street_address, b.suburb, b.city_postcode,
    b.email, b.phone, b.nzbn, b.gst_number
  INTO v_buyer
  FROM public.business_settings b
  WHERE b.row_marker = 'singleton';

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business settings not configured';
  END IF;

  v_buyer_missing := ARRAY[]::text[];
  IF NULLIF(trim(coalesce(v_buyer.legal_business_name, '')), '') IS NULL THEN v_buyer_missing := v_buyer_missing || 'legal_business_name'; END IF;
  IF NULLIF(trim(coalesce(v_buyer.street_address, '')), '') IS NULL THEN v_buyer_missing := v_buyer_missing || 'street_address'; END IF;
  IF NULLIF(trim(coalesce(v_buyer.suburb, '')), '') IS NULL THEN v_buyer_missing := v_buyer_missing || 'suburb'; END IF;
  IF NULLIF(trim(coalesce(v_buyer.city_postcode, '')), '') IS NULL THEN v_buyer_missing := v_buyer_missing || 'city_postcode'; END IF;
  IF array_length(v_buyer_missing, 1) > 0 THEN
    RAISE EXCEPTION 'Business settings incomplete: %', array_to_string(v_buyer_missing, ', ');
  END IF;

  -- Snapshot lines from Weekly Payroll (payable only, grouped by client invoice).
  -- min(uuid) does not exist in Postgres, so location_id is picked via
  -- (array_agg(... ORDER BY location_name NULLS LAST))[1] to match MIN(location_name).
  CREATE TEMP TABLE _ci_snapshot ON COMMIT DROP AS
  WITH lines AS (
    SELECT
      l.id AS payroll_line_id,
      l.invoice AS source_invoice_number,
      l.sale_date::date AS sale_date,
      l.customer_name,
      l.location_id,
      l.location_name,
      coalesce(l.price_ex_gst, 0) AS price_ex_gst,
      coalesce(l.actual_commission_amt_ex_gst, 0) AS actual_commission_amt_ex_gst,
      l.actual_commission_rate,
      l.actual_product_cost_ex_gst,l.actual_commissionable_ex_gst,l.product_type_actual
    FROM public.v_admin_payroll_lines_weekly l
    WHERE l.pay_week_start = p_pay_week_start
      AND l.payroll_status = 'payable'
      AND COALESCE(l.resolved_derived_staff_paid_id, l.derived_staff_paid_id) = p_staff_member_id
      AND l.invoice IS NOT NULL
  )
  SELECT
    ln.source_invoice_number,
    MIN(ln.sale_date) AS sale_date,
    MIN(ln.customer_name) AS customer_name,
    (array_agg(ln.location_id ORDER BY ln.location_name NULLS LAST))[1] AS location_id,
    MIN(ln.location_name) AS location_name,
    round(SUM(ln.price_ex_gst), 2) AS client_invoice_amount_ex_gst,
    round(SUM(ln.actual_commission_amt_ex_gst), 2) AS contractor_amount_ex_gst,
    SUM(ln.actual_commission_amt_ex_gst) AS raw_contractor_amount_ex_gst,
    jsonb_build_object('calculation_version',2,
      'product_cost_ex_gst',round(SUM(ln.actual_product_cost_ex_gst),2),
      'commissionable_ex_gst',round(SUM(ln.actual_commissionable_ex_gst),2),
      'applied_rates',jsonb_agg(DISTINCT jsonb_build_object('type',ln.product_type_actual,'rate',ln.actual_commission_rate)),
      'detail',private.contractor_source_invoice_calculation(ln.source_invoice_number,
        CASE WHEN count(DISTINCT ln.location_id)=1 THEN (array_agg(ln.location_id))[1] END,
        CASE WHEN count(DISTINCT ln.sale_date)=1 THEN MIN(ln.sale_date) END,p_staff_member_id),
      'payroll_lines',jsonb_agg(jsonb_build_object(
      'line_id', ln.payroll_line_id,
      'price_ex_gst', ln.price_ex_gst,
      'actual_commission_amt_ex_gst', ln.actual_commission_amt_ex_gst,
      'actual_commission_rate', ln.actual_commission_rate
    ) ORDER BY ln.payroll_line_id)) AS source_payload
  FROM lines ln
  GROUP BY ln.source_invoice_number
  ORDER BY MIN(ln.sale_date) NULLS LAST, ln.source_invoice_number;

  SELECT
    COUNT(*)::integer,
    COALESCE(round(SUM(raw_contractor_amount_ex_gst),2), 0),
    COALESCE(round(SUM(raw_contractor_amount_ex_gst),2)-SUM(contractor_amount_ex_gst),0)
  INTO v_line_count, v_subtotal, v_rounding_adjustment
  FROM pg_temp._ci_snapshot;

  IF v_line_count = 0 OR v_subtotal <= 0 THEN
    RAISE EXCEPTION 'No payable lines for this contractor in this pay week';
  END IF;

  IF v_contractor.contractor_gst_registered IS TRUE THEN
    v_gst := round(v_subtotal * 0.15, 2);
    v_gst_display := v_contractor.contractor_ird_number;
  ELSE
    v_gst := 0;
    v_gst_display := NULL;
  END IF;
  v_total := round(v_subtotal + v_gst, 2);

  v_base_invoice_number := v_invoice_code || '-' || private.contractor_invoice_week_suffix(v_week_end);

  IF p_replaces_invoice_id IS NOT NULL AND p_force_revision_number IS NULL THEN
    SELECT COALESCE(MAX(ci.revision_number), 0) + 1
    INTO v_revision_number
    FROM public.contractor_invoices ci
    WHERE ci.base_invoice_number = v_base_invoice_number
      AND ci.contractor_staff_member_id = p_staff_member_id
      AND ci.pay_week_start = p_pay_week_start;
  END IF;

  IF v_revision_number > 0 THEN
    v_invoice_number := v_base_invoice_number || '-R' || v_revision_number::text;
  ELSE
    v_invoice_number := v_base_invoice_number;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.contractor_invoices ci
    WHERE ci.contractor_staff_member_id = p_staff_member_id
      AND ci.pay_week_start = p_pay_week_start
      AND ci.status = 'created'
  ) THEN
    RAISE EXCEPTION 'An active invoice already exists for this contractor and pay week';
  END IF;

  INSERT INTO public.contractor_invoices (
    id, invoice_number, base_invoice_number, revision_number, status,
    pay_week_start, pay_week_end, invoice_date,
    contractor_staff_member_id,
    subtotal_ex_gst, gst_rate, gst_amount, total_inc_gst,rounding_adjustment_ex_gst,calculation_version,
    source_generated_at, internal_note,
    buyer_legal_business_name, buyer_trading_name,
    buyer_street_address, buyer_suburb, buyer_city_postcode,
    buyer_email, buyer_phone, buyer_nzbn, buyer_gst_number,
    contractor_full_name, contractor_display_name,
    contractor_invoice_name, contractor_company_name, contractor_invoice_code,
    contractor_email, contractor_gst_registered,
    contractor_gst_number_display_value,
    contractor_street_address, contractor_suburb, contractor_city_postcode,
    contractor_primary_location_id,
    replaces_invoice_id,
    created_by
  ) VALUES (
    v_invoice_id, v_invoice_number, v_base_invoice_number, v_revision_number, 'created',
    p_pay_week_start, v_week_end, v_invoice_date,
    p_staff_member_id,
    round(v_subtotal, 2), 0.15, v_gst, v_total,v_rounding_adjustment,2,
    v_source_generated_at, NULLIF(trim(coalesce(p_internal_note, '')), ''),
    v_buyer.legal_business_name, v_buyer.trading_name,
    v_buyer.street_address, v_buyer.suburb, v_buyer.city_postcode,
    v_buyer.email, v_buyer.phone, v_buyer.nzbn, v_buyer.gst_number,
    v_contractor.full_name, v_contractor.display_name,
    v_contractor.contractor_invoice_name, v_contractor.contractor_company_name, v_invoice_code,
    v_contractor.contractor_email, v_contractor.contractor_gst_registered,
    v_gst_display,
    v_contractor.contractor_street_address, v_contractor.contractor_suburb, v_contractor.contractor_city_postcode,
    v_contractor.primary_location_id,
    p_replaces_invoice_id,
    auth.uid()
  );

  INSERT INTO public.contractor_invoice_lines (
    contractor_invoice_id, line_number,
    sale_date, source_invoice_number, customer_name,
    location_id, location_name,
    client_invoice_amount_ex_gst, commission_percentage, contractor_amount_ex_gst,
    source_payload
  )
  SELECT
    v_invoice_id,
    row_number() OVER (ORDER BY sale_date NULLS LAST, source_invoice_number),
    sale_date,
    source_invoice_number,
    customer_name,
    location_id,
    location_name,
    client_invoice_amount_ex_gst,
    CASE WHEN client_invoice_amount_ex_gst > 0
      THEN round(contractor_amount_ex_gst / client_invoice_amount_ex_gst, 6)
      ELSE NULL
    END,
    contractor_amount_ex_gst,
    source_payload
  FROM pg_temp._ci_snapshot;

  IF p_replaces_invoice_id IS NOT NULL THEN
    UPDATE public.contractor_invoices
    SET replaced_by_invoice_id = v_invoice_id, updated_at = now()
    WHERE id = p_replaces_invoice_id;
  END IF;

  RETURN jsonb_build_object(
    'id', v_invoice_id,
    'invoice_number', v_invoice_number,
    'revision_number', v_revision_number,
    'subtotal_ex_gst', round(v_subtotal, 2),
    'gst_amount', v_gst,
    'total_inc_gst', v_total,
    'line_count', v_line_count
  );
END;
$function$;

CREATE FUNCTION public.create_contractor_invoice_v2(p_pay_week_start date,p_staff_member_id uuid,p_internal_note text DEFAULT NULL,p_replaces_invoice_id uuid DEFAULT NULL,p_force_revision_number integer DEFAULT NULL) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path='' AS $$ SELECT private.create_contractor_invoice_v2(p_pay_week_start,p_staff_member_id,p_internal_note,p_replaces_invoice_id,p_force_revision_number); $$;

DO $$ DECLARE f record; BEGIN FOR f IN SELECT p.oid::regprocedure signature FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname IN('public','private') AND p.proname IN('contractor_source_invoice_calculation','get_contractor_source_invoice_calculation','contractor_invoice_preview_v2','get_contractor_invoice_preview_v2','create_contractor_invoice_v2') LOOP EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC,anon,authenticated',f.signature); EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated',f.signature); END LOOP; END $$;

NOTIFY pgrst,'reload schema';
