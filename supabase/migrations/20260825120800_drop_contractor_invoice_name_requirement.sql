-- Naming simplification: the contractor invoice "person name" is now
-- `staff_members.full_name` everywhere. The legacy
-- `staff_members.contractor_invoice_name` override is no longer used by
-- any new logic and is no longer required for invoice creation.
--
-- This migration removes the server-side requirement / setup warning for
-- `contractor_invoice_name` in two places:
--   * get_contractor_invoice_batch — `setup_missing_fields` no longer
--     emits 'contractor_invoice_name' when both invoice_name and
--     company_name are blank. (The column is still returned in the row
--     shape for back-compat; clients simply ignore it.)
--   * create_contractor_invoice — the corresponding `v_missing` check is
--     removed so a contractor with no invoice_name but a valid full_name
--     (always required on staff_members) can have an invoice created.
--
-- Notes:
--   * The `staff_members.contractor_invoice_name` column is intentionally
--     LEFT IN PLACE (per spec) to avoid migration churn; we just no
--     longer depend on it.
--   * The `contractor_invoices.contractor_invoice_name` snapshot column
--     is also LEFT IN PLACE and still populated from whatever value (if
--     any) exists on `staff_members` at create time. No new logic reads
--     it; printed invoices use `contractor_full_name`.
--   * Function signatures, return shapes, indexes, and RLS are unchanged.

-- ---------------------------------------------------------------------------
-- get_contractor_invoice_batch
--   Identical to 20260825120600 except the 'contractor_invoice_name' case
--   in setup_missing_fields is removed.
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
#variable_conflict use_column
DECLARE
  v_pay_week_end date := (p_pay_week_start + interval '6 days')::date;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT private.user_has_page_access('contractor_invoices', 'view') THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH payable AS (
    SELECT
      COALESCE(l.resolved_derived_staff_paid_id, l.derived_staff_paid_id) AS staff_id,
      l.location_id,
      l.location_name,
      l.price_ex_gst,
      l.actual_commission_amt_ex_gst
    FROM public.v_admin_payroll_lines_weekly l
    WHERE l.pay_week_start = p_pay_week_start
      AND l.payroll_status = 'payable'
      AND COALESCE(l.resolved_derived_staff_paid_id, l.derived_staff_paid_id) IS NOT NULL
  ),
  per_contractor AS (
    SELECT
      p.staff_id                                       AS pc_staff_id,
      COUNT(*)::integer                                AS pc_line_count,
      COALESCE(SUM(p.actual_commission_amt_ex_gst), 0)::numeric AS pc_subtotal,
      string_agg(DISTINCT loc.code, ', ' ORDER BY loc.code)     AS pc_location_codes
    FROM payable p
    LEFT JOIN public.locations loc ON loc.id = p.location_id
    GROUP BY p.staff_id
  ),
  contractor_pool AS (
    SELECT
      s.id                          AS sm_id,
      s.full_name                   AS sm_full_name,
      s.display_name                AS sm_display_name,
      s.is_active                   AS sm_is_active,
      s.contractor_invoice_name     AS sm_invoice_name,
      s.contractor_company_name     AS sm_company_name,
      s.contractor_invoice_code     AS sm_invoice_code,
      s.contractor_email            AS sm_email,
      s.contractor_gst_registered   AS sm_gst_registered,
      s.contractor_ird_number       AS sm_ird_number,
      s.contractor_street_address   AS sm_street_address,
      s.contractor_suburb           AS sm_suburb,
      s.contractor_city_postcode    AS sm_city_postcode,
      s.primary_location_id         AS sm_primary_location_id,
      ploc.code                     AS sm_primary_location_code,
      ploc.name                     AS sm_primary_location_name
    FROM public.staff_members s
    LEFT JOIN public.locations ploc ON ploc.id = s.primary_location_id
    WHERE lower(coalesce(s.employment_type, '')) = 'contractor'
      AND (s.is_active = true OR EXISTS (
        SELECT 1 FROM per_contractor pc WHERE pc.pc_staff_id = s.id
      ))
  ),
  base AS (
    SELECT
      cp.*,
      COALESCE(pc.pc_line_count, 0)              AS base_line_count,
      COALESCE(pc.pc_subtotal, 0)::numeric        AS base_subtotal,
      pc.pc_location_codes                        AS base_location_codes
    FROM contractor_pool cp
    LEFT JOIN per_contractor pc ON pc.pc_staff_id = cp.sm_id
    WHERE p_include_zero_contractors OR COALESCE(pc.pc_line_count, 0) > 0
  ),
  active AS (
    SELECT ci.*
    FROM public.contractor_invoices ci
    WHERE ci.pay_week_start = p_pay_week_start
      AND ci.status = 'created'
  )
  SELECT
    b.sm_id                                                                AS staff_member_id,
    b.sm_full_name                                                         AS contractor_full_name,
    b.sm_display_name                                                      AS contractor_display_name,
    b.sm_invoice_name                                                      AS contractor_invoice_name,
    b.sm_company_name                                                      AS contractor_company_name,
    b.sm_invoice_code                                                      AS contractor_invoice_code,
    b.sm_email                                                             AS contractor_email,
    b.sm_gst_registered                                                    AS contractor_gst_registered,
    b.sm_ird_number                                                        AS contractor_ird_number,
    b.sm_street_address                                                    AS contractor_street_address,
    b.sm_suburb                                                            AS contractor_suburb,
    b.sm_city_postcode                                                     AS contractor_city_postcode,
    b.sm_primary_location_id                                               AS contractor_primary_location_id,
    b.sm_primary_location_code                                             AS contractor_primary_location_code,
    b.sm_primary_location_name                                             AS contractor_primary_location_name,
    b.sm_is_active                                                         AS contractor_is_active,
    p_pay_week_start                                                       AS pay_week_start,
    v_pay_week_end                                                         AS pay_week_end,
    b.base_line_count                                                      AS payable_line_count,
    round(b.base_subtotal, 2)                                              AS payable_subtotal_ex_gst,
    CASE WHEN b.sm_gst_registered IS TRUE
         THEN round(b.base_subtotal * 0.15, 2)
         ELSE 0::numeric
    END                                                                    AS payable_gst_amount,
    CASE WHEN b.sm_gst_registered IS TRUE
         THEN round(b.base_subtotal * 1.15, 2)
         ELSE round(b.base_subtotal, 2)
    END                                                                    AS payable_total_inc_gst,
    b.base_location_codes                                                  AS payable_location_codes,
    act.id                                                                 AS active_invoice_id,
    act.invoice_number                                                     AS active_invoice_number,
    act.status                                                             AS active_invoice_status,
    act.revision_number                                                    AS active_invoice_revision_number,
    act.total_inc_gst                                                      AS active_invoice_total_inc_gst,
    act.created_at                                                         AS active_invoice_created_at,
    ARRAY_REMOVE(ARRAY[
      CASE WHEN NULLIF(trim(coalesce(b.sm_invoice_code,'')), '') IS NULL
           THEN 'contractor_invoice_code' END,
      CASE WHEN b.sm_gst_registered IS NULL
           THEN 'contractor_gst_registered' END,
      CASE WHEN NULLIF(trim(coalesce(b.sm_street_address,'')), '') IS NULL
           THEN 'contractor_street_address' END,
      CASE WHEN NULLIF(trim(coalesce(b.sm_suburb,'')), '') IS NULL
           THEN 'contractor_suburb' END,
      CASE WHEN NULLIF(trim(coalesce(b.sm_city_postcode,'')), '') IS NULL
           THEN 'contractor_city_postcode' END,
      CASE WHEN b.sm_gst_registered IS TRUE
           AND NULLIF(trim(coalesce(b.sm_ird_number,'')), '') IS NULL
           THEN 'contractor_ird_number' END
    ], NULL)                                                               AS setup_missing_fields
  FROM base b
  LEFT JOIN active act ON act.contractor_staff_member_id = b.sm_id
  ORDER BY
    COALESCE(NULLIF(trim(b.sm_display_name), ''), b.sm_full_name) COLLATE "C";
END;
$$;

ALTER FUNCTION public.get_contractor_invoice_batch(date, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_contractor_invoice_batch(date, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_contractor_invoice_batch(date, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_contractor_invoice_batch(date, boolean) TO service_role;

-- ---------------------------------------------------------------------------
-- create_contractor_invoice
--   Identical to 20260825120700 except the contractor_invoice_name vs
--   company_name "missing" check is removed. Header still snapshots
--   `v_contractor.contractor_invoice_name` (may be NULL) into the
--   `contractor_invoices` row for completeness / back-compat.
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
