-- Contractor Invoices RPCs:
--   get_contractor_invoice_batch(p_pay_week_start, p_include_zero_contractors)
--   get_contractor_invoice_preview(p_pay_week_start, p_staff_member_id)
--   create_contractor_invoice(p_pay_week_start, p_staff_member_id, p_internal_note)
--   void_contractor_invoice(p_invoice_id, p_void_reason)
--   replace_contractor_invoice(p_invoice_id, p_void_reason, p_internal_note)
--   get_contractor_invoice(p_invoice_id)
--   list_recent_contractor_invoice_weeks() — for the pay week selector
--
-- All RPCs gate via private.user_has_page_access('contractor_invoices', ...).
-- View ⇒ read; Full ⇒ create/void/replace.
-- Snapshot data is computed from v_admin_payroll_lines_weekly (payable lines only).

-- ---------------------------------------------------------------------------
-- Internal helpers (kept private to this migration)
-- ---------------------------------------------------------------------------

-- pay-week invoice-number suffix: pay_week_end as 'YY-MMDD' (NZ time).
CREATE OR REPLACE FUNCTION private.contractor_invoice_week_suffix(p_pay_week_end date)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT to_char(p_pay_week_end, 'YY-MMDD');
$$;

ALTER FUNCTION private.contractor_invoice_week_suffix(date) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.contractor_invoice_week_suffix(date) FROM PUBLIC;

-- ---------------------------------------------------------------------------
-- get_contractor_invoice_batch
--   Per-contractor totals for a pay week. Includes contractor identity columns
--   needed by the batch UI (badges, GST status, invoice no when saved).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_contractor_invoice_batch(
  p_pay_week_start date,
  p_include_zero_contractors boolean DEFAULT false
)
RETURNS TABLE (
  staff_member_id uuid,
  contractor_full_name text,
  contractor_display_name text,
  contractor_invoice_name text,
  contractor_company_name text,
  contractor_invoice_code text,
  contractor_email text,
  contractor_gst_registered boolean,
  contractor_ird_number text,
  contractor_street_address text,
  contractor_suburb text,
  contractor_city_postcode text,
  contractor_primary_location_id uuid,
  contractor_primary_location_code text,
  contractor_primary_location_name text,
  contractor_is_active boolean,
  pay_week_start date,
  pay_week_end date,
  payable_line_count integer,
  payable_subtotal_ex_gst numeric,
  payable_gst_amount numeric,
  payable_total_inc_gst numeric,
  payable_location_codes text,
  active_invoice_id uuid,
  active_invoice_number text,
  active_invoice_status text,
  active_invoice_revision_number integer,
  active_invoice_total_inc_gst numeric,
  active_invoice_created_at timestamptz,
  setup_missing_fields text[]
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT private.user_has_page_access('contractor_invoices', 'view') THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH week AS (
    SELECT
      p_pay_week_start AS pay_week_start,
      (p_pay_week_start + interval '6 days')::date AS pay_week_end
  ),
  payable AS (
    SELECT
      COALESCE(l.resolved_derived_staff_paid_id, l.derived_staff_paid_id) AS staff_id,
      l.location_id,
      l.location_name,
      l.price_ex_gst,
      l.actual_commission_amt_ex_gst
    FROM public.v_admin_payroll_lines_weekly l
    WHERE l.pay_week_start = (SELECT pay_week_start FROM week)
      AND l.payroll_status = 'payable'
      AND COALESCE(l.resolved_derived_staff_paid_id, l.derived_staff_paid_id) IS NOT NULL
  ),
  per_contractor AS (
    SELECT
      p.staff_id,
      COUNT(*)::integer AS payable_line_count,
      COALESCE(SUM(p.actual_commission_amt_ex_gst), 0)::numeric AS subtotal_ex_gst,
      string_agg(
        DISTINCT loc.code,
        ', ' ORDER BY loc.code
      ) AS location_codes
    FROM payable p
    LEFT JOIN public.locations loc ON loc.id = p.location_id
    GROUP BY p.staff_id
  ),
  contractor_pool AS (
    SELECT
      s.id AS staff_member_id,
      s.full_name,
      s.display_name,
      s.is_active,
      s.contractor_invoice_name,
      s.contractor_company_name,
      s.contractor_invoice_code,
      s.contractor_email,
      s.contractor_gst_registered,
      s.contractor_ird_number,
      s.contractor_street_address,
      s.contractor_suburb,
      s.contractor_city_postcode,
      s.primary_location_id,
      ploc.code AS primary_location_code,
      ploc.name AS primary_location_name
    FROM public.staff_members s
    LEFT JOIN public.locations ploc ON ploc.id = s.primary_location_id
    WHERE lower(coalesce(s.employment_type, '')) = 'contractor'
      AND (s.is_active = true OR EXISTS (
        SELECT 1 FROM per_contractor pc WHERE pc.staff_id = s.id
      ))
  ),
  base AS (
    SELECT
      cp.*,
      COALESCE(pc.payable_line_count, 0) AS payable_line_count,
      COALESCE(pc.subtotal_ex_gst, 0)::numeric AS subtotal_ex_gst,
      pc.location_codes
    FROM contractor_pool cp
    LEFT JOIN per_contractor pc ON pc.staff_id = cp.staff_member_id
    WHERE p_include_zero_contractors OR COALESCE(pc.payable_line_count, 0) > 0
  ),
  active AS (
    SELECT ci.*
    FROM public.contractor_invoices ci
    WHERE ci.pay_week_start = (SELECT pay_week_start FROM week)
      AND ci.status = 'created'
  )
  SELECT
    b.staff_member_id,
    b.full_name AS contractor_full_name,
    b.display_name AS contractor_display_name,
    b.contractor_invoice_name,
    b.contractor_company_name,
    b.contractor_invoice_code,
    b.contractor_email,
    b.contractor_gst_registered,
    b.contractor_ird_number,
    b.contractor_street_address,
    b.contractor_suburb,
    b.contractor_city_postcode,
    b.primary_location_id AS contractor_primary_location_id,
    b.primary_location_code AS contractor_primary_location_code,
    b.primary_location_name AS contractor_primary_location_name,
    b.is_active AS contractor_is_active,
    (SELECT pay_week_start FROM week) AS pay_week_start,
    (SELECT pay_week_end FROM week) AS pay_week_end,
    b.payable_line_count,
    round(b.subtotal_ex_gst, 2) AS payable_subtotal_ex_gst,
    CASE WHEN b.contractor_gst_registered IS TRUE
      THEN round(b.subtotal_ex_gst * 0.15, 2)
      ELSE 0::numeric
    END AS payable_gst_amount,
    CASE WHEN b.contractor_gst_registered IS TRUE
      THEN round(b.subtotal_ex_gst * 1.15, 2)
      ELSE round(b.subtotal_ex_gst, 2)
    END AS payable_total_inc_gst,
    b.location_codes AS payable_location_codes,
    act.id AS active_invoice_id,
    act.invoice_number AS active_invoice_number,
    act.status AS active_invoice_status,
    act.revision_number AS active_invoice_revision_number,
    act.total_inc_gst AS active_invoice_total_inc_gst,
    act.created_at AS active_invoice_created_at,
    -- Missing contractor setup fields (for UI badges + preview warnings).
    ARRAY_REMOVE(ARRAY[
      CASE WHEN NULLIF(trim(coalesce(b.contractor_invoice_code,'')),'') IS NULL
           THEN 'contractor_invoice_code' END,
      CASE WHEN b.contractor_gst_registered IS NULL
           THEN 'contractor_gst_registered' END,
      CASE WHEN NULLIF(trim(coalesce(b.contractor_street_address,'')),'') IS NULL
           THEN 'contractor_street_address' END,
      CASE WHEN NULLIF(trim(coalesce(b.contractor_suburb,'')),'') IS NULL
           THEN 'contractor_suburb' END,
      CASE WHEN NULLIF(trim(coalesce(b.contractor_city_postcode,'')),'') IS NULL
           THEN 'contractor_city_postcode' END,
      CASE WHEN NULLIF(trim(coalesce(b.contractor_invoice_name,'')),'') IS NULL
           AND NULLIF(trim(coalesce(b.contractor_company_name,'')),'') IS NULL
           THEN 'contractor_invoice_name' END,
      CASE WHEN b.contractor_gst_registered IS TRUE
           AND NULLIF(trim(coalesce(b.contractor_ird_number,'')),'') IS NULL
           THEN 'contractor_ird_number' END
    ], NULL) AS setup_missing_fields
  FROM base b
  LEFT JOIN active act ON act.contractor_staff_member_id = b.staff_member_id
  ORDER BY
    COALESCE(NULLIF(trim(b.display_name),''), b.full_name) COLLATE "C";
END;
$$;

ALTER FUNCTION public.get_contractor_invoice_batch(date, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_contractor_invoice_batch(date, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_contractor_invoice_batch(date, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_contractor_invoice_batch(date, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- get_contractor_invoice_preview — preview line table for one contractor / week.
-- Returns the lines (grouped by client invoice number) PLUS the per-contractor
-- header info needed for the preview (so the modal can render setup warnings).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_contractor_invoice_preview(
  p_pay_week_start date,
  p_staff_member_id uuid
)
RETURNS TABLE (
  staff_member_id uuid,
  pay_week_start date,
  pay_week_end date,
  source_invoice_number text,
  sale_date date,
  customer_name text,
  location_id uuid,
  location_name text,
  client_invoice_amount_ex_gst numeric,
  contractor_amount_ex_gst numeric,
  commission_percentage numeric
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT private.user_has_page_access('contractor_invoices', 'view') THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH lines AS (
    SELECT
      l.invoice AS source_invoice_number,
      l.sale_date::date AS sale_date,
      l.customer_name,
      l.location_id,
      l.location_name,
      l.price_ex_gst,
      l.actual_commission_amt_ex_gst
    FROM public.v_admin_payroll_lines_weekly l
    WHERE l.pay_week_start = p_pay_week_start
      AND l.payroll_status = 'payable'
      AND COALESCE(l.resolved_derived_staff_paid_id, l.derived_staff_paid_id) = p_staff_member_id
      AND l.invoice IS NOT NULL
  ),
  grouped AS (
    SELECT
      ln.source_invoice_number,
      MIN(ln.sale_date) AS sale_date,
      MIN(ln.customer_name) AS customer_name,
      MIN(ln.location_id) AS location_id,
      MIN(ln.location_name) AS location_name,
      round(SUM(coalesce(ln.price_ex_gst, 0)), 2) AS client_invoice_amount_ex_gst,
      round(SUM(coalesce(ln.actual_commission_amt_ex_gst, 0)), 2) AS contractor_amount_ex_gst
    FROM lines ln
    GROUP BY ln.source_invoice_number
  )
  SELECT
    p_staff_member_id,
    p_pay_week_start,
    (p_pay_week_start + interval '6 days')::date,
    g.source_invoice_number,
    g.sale_date,
    g.customer_name,
    g.location_id,
    g.location_name,
    g.client_invoice_amount_ex_gst,
    g.contractor_amount_ex_gst,
    CASE WHEN g.client_invoice_amount_ex_gst > 0
      THEN round(g.contractor_amount_ex_gst / g.client_invoice_amount_ex_gst, 6)
      ELSE NULL
    END AS commission_percentage
  FROM grouped g
  ORDER BY g.sale_date NULLS LAST, g.source_invoice_number;
END;
$$;

ALTER FUNCTION public.get_contractor_invoice_preview(date, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_contractor_invoice_preview(date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_contractor_invoice_preview(date, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_contractor_invoice_preview(date, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- create_contractor_invoice
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_contractor_invoice(
  p_pay_week_start date,
  p_staff_member_id uuid,
  p_internal_note text DEFAULT NULL,
  p_replaces_invoice_id uuid DEFAULT NULL,
  p_force_revision_number integer DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_week_end date;
  v_invoice_date date := (now() AT TIME ZONE 'Pacific/Auckland')::date;
  v_source_generated_at timestamptz := now();
  v_invoice_id uuid := gen_random_uuid();
  v_subtotal numeric := 0;
  v_gst numeric := 0;
  v_total numeric := 0;
  v_line_count integer := 0;
  v_base_invoice_number text;
  v_invoice_number text;
  v_revision_number integer := COALESCE(p_force_revision_number, 0);
  -- Contractor snapshot
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

  -- Contractor + employment_type validation.
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
  v_missing := ARRAY[]::text[];
  v_invoice_code := NULLIF(trim(coalesce(v_contractor.contractor_invoice_code, '')), '');
  IF v_invoice_code IS NULL THEN v_missing := v_missing || 'contractor_invoice_code'; END IF;
  IF v_contractor.contractor_gst_registered IS NULL THEN v_missing := v_missing || 'contractor_gst_registered'; END IF;
  IF NULLIF(trim(coalesce(v_contractor.contractor_street_address, '')), '') IS NULL THEN v_missing := v_missing || 'contractor_street_address'; END IF;
  IF NULLIF(trim(coalesce(v_contractor.contractor_suburb, '')), '') IS NULL THEN v_missing := v_missing || 'contractor_suburb'; END IF;
  IF NULLIF(trim(coalesce(v_contractor.contractor_city_postcode, '')), '') IS NULL THEN v_missing := v_missing || 'contractor_city_postcode'; END IF;
  IF NULLIF(trim(coalesce(v_contractor.contractor_invoice_name, '')), '') IS NULL
     AND NULLIF(trim(coalesce(v_contractor.contractor_company_name, '')), '') IS NULL THEN
    v_missing := v_missing || 'contractor_invoice_name';
  END IF;
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
      l.actual_commission_rate
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
    MIN(ln.location_id) AS location_id,
    MIN(ln.location_name) AS location_name,
    round(SUM(ln.price_ex_gst), 2) AS client_invoice_amount_ex_gst,
    round(SUM(ln.actual_commission_amt_ex_gst), 2) AS contractor_amount_ex_gst,
    jsonb_agg(jsonb_build_object(
      'line_id', ln.payroll_line_id,
      'price_ex_gst', ln.price_ex_gst,
      'actual_commission_amt_ex_gst', ln.actual_commission_amt_ex_gst,
      'actual_commission_rate', ln.actual_commission_rate
    ) ORDER BY ln.payroll_line_id) AS source_payload
  FROM lines ln
  GROUP BY ln.source_invoice_number
  ORDER BY MIN(ln.sale_date) NULLS LAST, ln.source_invoice_number;

  SELECT
    COUNT(*)::integer,
    COALESCE(SUM(contractor_amount_ex_gst), 0)
  INTO v_line_count, v_subtotal
  FROM _ci_snapshot;

  IF v_line_count = 0 OR v_subtotal <= 0 THEN
    RAISE EXCEPTION 'No payable lines for this contractor in this pay week';
  END IF;

  -- GST + total
  IF v_contractor.contractor_gst_registered IS TRUE THEN
    v_gst := round(v_subtotal * 0.15, 2);
    v_gst_display := v_contractor.contractor_ird_number;
  ELSE
    v_gst := 0;
    v_gst_display := NULL;
  END IF;
  v_total := round(v_subtotal + v_gst, 2);

  -- Invoice number: <CODE>-<YY>-<MMDD> with optional -R<n>.
  v_base_invoice_number := v_invoice_code || '-' || private.contractor_invoice_week_suffix(v_week_end);

  IF p_replaces_invoice_id IS NOT NULL AND p_force_revision_number IS NULL THEN
    -- Compute next revision by examining existing rows for the same base number.
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

  -- Active-row guard (also enforced by partial unique index).
  IF EXISTS (
    SELECT 1 FROM public.contractor_invoices ci
    WHERE ci.contractor_staff_member_id = p_staff_member_id
      AND ci.pay_week_start = p_pay_week_start
      AND ci.status = 'created'
  ) THEN
    RAISE EXCEPTION 'An active invoice already exists for this contractor and pay week';
  END IF;

  -- Insert header
  INSERT INTO public.contractor_invoices (
    id, invoice_number, base_invoice_number, revision_number, status,
    pay_week_start, pay_week_end, invoice_date,
    contractor_staff_member_id,
    subtotal_ex_gst, gst_rate, gst_amount, total_inc_gst,
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
    round(v_subtotal, 2), 0.15, v_gst, v_total,
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

  -- Insert lines
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
  FROM _ci_snapshot;

  -- Link replacement back-pointer on the replaced invoice (already voided by replace fn).
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
$$;

ALTER FUNCTION public.create_contractor_invoice(date, uuid, text, uuid, integer) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.create_contractor_invoice(date, uuid, text, uuid, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_contractor_invoice(date, uuid, text, uuid, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_contractor_invoice(date, uuid, text, uuid, integer) TO service_role;

-- ---------------------------------------------------------------------------
-- void_contractor_invoice
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.void_contractor_invoice(
  p_invoice_id uuid,
  p_void_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_row public.contractor_invoices%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT private.user_has_page_access('contractor_invoices', 'full') THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  IF p_invoice_id IS NULL THEN
    RAISE EXCEPTION 'p_invoice_id is required';
  END IF;

  IF NULLIF(trim(coalesce(p_void_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Void reason is required';
  END IF;

  SELECT * INTO v_row FROM public.contractor_invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invoice not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_row.status <> 'created' THEN
    RAISE EXCEPTION 'Only active (created) invoices may be voided';
  END IF;

  UPDATE public.contractor_invoices
  SET status = 'voided',
      voided_at = now(),
      voided_by = auth.uid(),
      void_reason = trim(p_void_reason),
      updated_at = now()
  WHERE id = p_invoice_id
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

ALTER FUNCTION public.void_contractor_invoice(uuid, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.void_contractor_invoice(uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.void_contractor_invoice(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.void_contractor_invoice(uuid, text) TO service_role;

-- ---------------------------------------------------------------------------
-- replace_contractor_invoice — atomic void-and-recreate.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.replace_contractor_invoice(
  p_invoice_id uuid,
  p_void_reason text,
  p_internal_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_old public.contractor_invoices%ROWTYPE;
  v_next_rev integer;
  v_result jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT private.user_has_page_access('contractor_invoices', 'full') THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  IF NULLIF(trim(coalesce(p_void_reason, '')), '') IS NULL THEN
    RAISE EXCEPTION 'Void reason is required';
  END IF;

  SELECT * INTO v_old FROM public.contractor_invoices WHERE id = p_invoice_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Invoice not found' USING ERRCODE = 'P0002';
  END IF;
  IF v_old.status <> 'created' THEN
    RAISE EXCEPTION 'Only active (created) invoices may be replaced';
  END IF;

  -- Void the old invoice first (atomic with the recreate).
  UPDATE public.contractor_invoices
  SET status = 'voided',
      voided_at = now(),
      voided_by = auth.uid(),
      void_reason = trim(p_void_reason),
      updated_at = now()
  WHERE id = p_invoice_id;

  SELECT COALESCE(MAX(revision_number), 0) + 1
  INTO v_next_rev
  FROM public.contractor_invoices
  WHERE base_invoice_number = v_old.base_invoice_number
    AND contractor_staff_member_id = v_old.contractor_staff_member_id
    AND pay_week_start = v_old.pay_week_start;

  v_result := public.create_contractor_invoice(
    v_old.pay_week_start,
    v_old.contractor_staff_member_id,
    p_internal_note,
    p_invoice_id,
    v_next_rev
  );

  RETURN v_result;
END;
$$;

ALTER FUNCTION public.replace_contractor_invoice(uuid, text, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.replace_contractor_invoice(uuid, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_contractor_invoice(uuid, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.replace_contractor_invoice(uuid, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- get_contractor_invoice — full saved snapshot (header + lines).
-- Returned as a single jsonb so the frontend can render with one round trip.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_contractor_invoice(p_invoice_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_header jsonb;
  v_lines jsonb;
  v_replaces_number text;
  v_replaced_by_number text;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT private.user_has_page_access('contractor_invoices', 'view') THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  SELECT to_jsonb(ci.*) INTO v_header
  FROM public.contractor_invoices ci
  WHERE ci.id = p_invoice_id;

  IF v_header IS NULL THEN
    RAISE EXCEPTION 'Invoice not found' USING ERRCODE = 'P0002';
  END IF;

  SELECT ci.invoice_number INTO v_replaces_number
  FROM public.contractor_invoices ci
  WHERE ci.id = (v_header->>'replaces_invoice_id')::uuid;

  SELECT ci.invoice_number INTO v_replaced_by_number
  FROM public.contractor_invoices ci
  WHERE ci.id = (v_header->>'replaced_by_invoice_id')::uuid;

  SELECT COALESCE(jsonb_agg(to_jsonb(cl.*) ORDER BY cl.line_number), '[]'::jsonb) INTO v_lines
  FROM public.contractor_invoice_lines cl
  WHERE cl.contractor_invoice_id = p_invoice_id;

  RETURN jsonb_build_object(
    'header', v_header,
    'lines', v_lines,
    'replaces_invoice_number', v_replaces_number,
    'replaced_by_invoice_number', v_replaced_by_number
  );
END;
$$;

ALTER FUNCTION public.get_contractor_invoice(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_contractor_invoice(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_contractor_invoice(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_contractor_invoice(uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- list_contractor_invoice_pay_weeks — distinct pay weeks ever payable, newest first.
-- Mirrors get_admin_payroll_summary_weekly's pattern of populating the week selector.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_contractor_invoice_pay_weeks()
RETURNS TABLE (pay_week_start date, pay_week_end date)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT private.user_has_page_access('contractor_invoices', 'view') THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH from_payroll AS (
    SELECT DISTINCT s.pay_week_start, s.pay_week_end
    FROM public.v_admin_payroll_summary_weekly s
  ),
  from_invoices AS (
    SELECT DISTINCT ci.pay_week_start, ci.pay_week_end
    FROM public.contractor_invoices ci
  )
  SELECT pay_week_start, pay_week_end FROM (
    SELECT pay_week_start, pay_week_end FROM from_payroll
    UNION
    SELECT pay_week_start, pay_week_end FROM from_invoices
  ) u
  ORDER BY pay_week_start DESC;
END;
$$;

ALTER FUNCTION public.list_contractor_invoice_pay_weeks() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.list_contractor_invoice_pay_weeks() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_contractor_invoice_pay_weeks() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_contractor_invoice_pay_weeks() TO service_role;
