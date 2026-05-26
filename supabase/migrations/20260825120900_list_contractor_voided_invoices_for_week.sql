-- Voided-invoice visibility on the Contractor Invoices batch page.
--
-- The existing `get_contractor_invoice_batch` RPC intentionally returns
-- one row per contractor with the single *active* invoice for the pay
-- week (or NULL if none). We do not extend it — it's already wired into
-- the batch table layout and creation flow, and mixing in voided rows
-- would break its "one row per contractor" semantics + complicate the
-- partial-unique-index guard logic.
--
-- Instead this migration adds a dedicated read-only RPC that returns
-- *voided* contractor invoices for a given pay week, joined with enough
-- snapshot + staff data to render a compact secondary table on the batch
-- page. The frontend only calls it when the user opts in via the
-- "Show voided invoices" toggle.
--
-- Security: same `contractor_invoices/view` page-access check as the
-- other view-side RPCs. Idempotent — safe to re-run.

CREATE OR REPLACE FUNCTION public.list_contractor_voided_invoices_for_week(
  p_pay_week_start date
)
RETURNS TABLE (
  invoice_id uuid,
  invoice_number text,
  revision_number integer,
  staff_member_id uuid,
  contractor_full_name text,
  contractor_display_name text,
  contractor_company_name text,
  contractor_is_active boolean,
  contractor_gst_registered boolean,
  contractor_primary_location_code text,
  pay_week_start date,
  pay_week_end date,
  subtotal_ex_gst numeric,
  gst_amount numeric,
  total_inc_gst numeric,
  voided_at timestamptz,
  void_reason text,
  created_at timestamptz,
  replaced_by_invoice_id uuid,
  replaced_by_invoice_number text
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
  SELECT
    ci.id                                AS invoice_id,
    ci.invoice_number                    AS invoice_number,
    ci.revision_number                   AS revision_number,
    ci.contractor_staff_member_id        AS staff_member_id,
    ci.contractor_full_name              AS contractor_full_name,
    ci.contractor_display_name           AS contractor_display_name,
    ci.contractor_company_name           AS contractor_company_name,
    COALESCE(s.is_active, false)         AS contractor_is_active,
    ci.contractor_gst_registered         AS contractor_gst_registered,
    ploc.code                            AS contractor_primary_location_code,
    ci.pay_week_start                    AS pay_week_start,
    ci.pay_week_end                      AS pay_week_end,
    ci.subtotal_ex_gst                   AS subtotal_ex_gst,
    ci.gst_amount                        AS gst_amount,
    ci.total_inc_gst                     AS total_inc_gst,
    ci.voided_at                         AS voided_at,
    ci.void_reason                       AS void_reason,
    ci.created_at                        AS created_at,
    ci.replaced_by_invoice_id            AS replaced_by_invoice_id,
    rep.invoice_number                   AS replaced_by_invoice_number
  FROM public.contractor_invoices ci
  LEFT JOIN public.staff_members s
         ON s.id = ci.contractor_staff_member_id
  LEFT JOIN public.locations ploc
         ON ploc.id = s.primary_location_id
  LEFT JOIN public.contractor_invoices rep
         ON rep.id = ci.replaced_by_invoice_id
  WHERE ci.pay_week_start = p_pay_week_start
    AND ci.status = 'voided'
  ORDER BY
    COALESCE(NULLIF(trim(ci.contractor_display_name), ''), ci.contractor_full_name) COLLATE "C",
    ci.created_at DESC;
END;
$$;

ALTER FUNCTION public.list_contractor_voided_invoices_for_week(date) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.list_contractor_voided_invoices_for_week(date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_contractor_voided_invoices_for_week(date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_contractor_voided_invoices_for_week(date) TO service_role;
