-- Bugfix sweep for contractor-invoice RETURNS TABLE functions.
--
-- Same PostgreSQL plpgsql gotcha as 20260825120500 (list_contractor_invoice_pay_weeks):
-- `RETURNS TABLE (col_name type, ...)` declares implicit OUT params with those
-- exact names, and bare column references in the body conflict with them when
-- a CTE / join also exposes a column of the same name. Default
-- `#variable_conflict error` raises `column reference "..." is ambiguous` at
-- runtime — observed live as:
--   ERROR: get_contractor_invoice_batch: column reference "pay_week_start" is ambiguous
--
-- This migration:
--   1. Replaces get_contractor_invoice_batch with a version that removes the
--      `week` CTE (and its bare `(SELECT pay_week_start FROM week)` refs) in
--      favour of the function parameter + a declared local variable, and
--      uses distinct `sm_` / `pc_` / `base_` aliases inside every CTE so no
--      bare reference can collide with an OUT param name later.
--   2. Replaces get_contractor_invoice_preview defensively with
--      `#variable_conflict use_column` so any future bare reference resolves
--      to the column and not the OUT param. Function body left otherwise
--      unchanged — all existing refs are already qualified.
--
-- Function signatures unchanged. Return shape / row order / row contents
-- unchanged. No frontend changes required.

-- ---------------------------------------------------------------------------
-- get_contractor_invoice_batch
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
      CASE WHEN NULLIF(trim(coalesce(b.sm_invoice_name,'')), '') IS NULL
           AND NULLIF(trim(coalesce(b.sm_company_name,'')), '') IS NULL
           THEN 'contractor_invoice_name' END,
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
-- get_contractor_invoice_preview — defensive: pin variable_conflict policy.
-- Body otherwise unchanged from 20260825120400; all refs already qualified.
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
      ln.ln_invoice_no                                                 AS g_invoice_no,
      MIN(ln.ln_sale_date)                                              AS g_sale_date,
      MIN(ln.ln_customer_name)                                          AS g_customer_name,
      MIN(ln.ln_location_id)                                            AS g_location_id,
      MIN(ln.ln_location_name)                                          AS g_location_name,
      round(SUM(coalesce(ln.ln_price_ex_gst, 0)), 2)                    AS g_client_amount,
      round(SUM(coalesce(ln.ln_commission_ex_gst, 0)), 2)               AS g_contractor_amount
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
