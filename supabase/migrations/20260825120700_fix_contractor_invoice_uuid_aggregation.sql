-- Bugfix: PostgreSQL does not provide min(uuid) / max(uuid) aggregates, so
-- the previous grouping (MIN(location_id)) raised:
--   ERROR: function min(uuid) does not exist
-- when get_contractor_invoice_preview was called from the Preview modal.
-- create_contractor_invoice had the same MIN(location_id) inside its
-- temp-table snapshot CTE, so it would have failed identically at Create time.
--
-- Fix pattern (per user guidance — no uuid::text casts):
--   (array_agg(<uuid_col> ORDER BY <location_name> NULLS LAST))[1]
-- paired with MIN(location_name). Identical ORDER BY on the pair guarantees
-- the selected location_id always matches the selected location_name (the
-- first one alphabetically by location name). In practice every Kitomba
-- client invoice is taken at a single salon, so all rows in a group share
-- the same location_id anyway and the pick is purely deterministic noise.
-- Front-end multi-location detection (invoiceHasMultipleLocations) compares
-- DISTINCT location_ids across saved invoice lines, so behaviour is preserved.
--
-- Bodies of both functions are otherwise identical to their previous
-- definitions (20260825120600 / 20260825120400). Signatures and return
-- shapes unchanged. No frontend changes required.

-- ---------------------------------------------------------------------------
-- get_contractor_invoice_preview — replace MIN(ln_location_id)
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
#variable_conflict use_column
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
      l.invoice                          AS ln_invoice_no,
      l.sale_date::date                  AS ln_sale_date,
      l.customer_name                    AS ln_customer_name,
      l.location_id                      AS ln_location_id,
      l.location_name                    AS ln_location_name,
      l.price_ex_gst                     AS ln_price_ex_gst,
      l.actual_commission_amt_ex_gst     AS ln_commission_ex_gst
    FROM public.v_admin_payroll_lines_weekly l
    WHERE l.pay_week_start = p_pay_week_start
      AND l.payroll_status = 'payable'
      AND COALESCE(l.resolved_derived_staff_paid_id, l.derived_staff_paid_id) = p_staff_member_id
      AND l.invoice IS NOT NULL
  ),
  grouped AS (
    SELECT
      ln.ln_invoice_no                                                       AS g_invoice_no,
      MIN(ln.ln_sale_date)                                                    AS g_sale_date,
      MIN(ln.ln_customer_name)                                                AS g_customer_name,
      (array_agg(ln.ln_location_id ORDER BY ln.ln_location_name NULLS LAST))[1]   AS g_location_id,
      MIN(ln.ln_location_name)                                                AS g_location_name,
      round(SUM(coalesce(ln.ln_price_ex_gst, 0)), 2)                          AS g_client_amount,
      round(SUM(coalesce(ln.ln_commission_ex_gst, 0)), 2)                     AS g_contractor_amount
    FROM lines ln
    GROUP BY ln.ln_invoice_no
  )
  SELECT
    p_staff_member_id                                                    AS staff_member_id,
    p_pay_week_start                                                     AS pay_week_start,
    (p_pay_week_start + interval '6 days')::date                         AS pay_week_end,
    g.g_invoice_no                                                       AS source_invoice_number,
    g.g_sale_date                                                        AS sale_date,
    g.g_customer_name                                                    AS customer_name,
    g.g_location_id                                                      AS location_id,
    g.g_location_name                                                    AS location_name,
    g.g_client_amount                                                    AS client_invoice_amount_ex_gst,
    g.g_contractor_amount                                                AS contractor_amount_ex_gst,
    CASE WHEN g.g_client_amount > 0
         THEN round(g.g_contractor_amount / g.g_client_amount, 6)
         ELSE NULL
    END                                                                  AS commission_percentage
  FROM grouped g
  ORDER BY g.g_sale_date NULLS LAST, g.g_invoice_no;
END;
$$;

ALTER FUNCTION public.get_contractor_invoice_preview(date, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_contractor_invoice_preview(date, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_contractor_invoice_preview(date, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_contractor_invoice_preview(date, uuid) TO service_role;

-- ---------------------------------------------------------------------------
-- create_contractor_invoice — replace MIN(location_id) inside snapshot CTE.
-- Body otherwise identical to 20260825120400.
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
    (array_agg(ln.location_id ORDER BY ln.location_name NULLS LAST))[1] AS location_id,
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
