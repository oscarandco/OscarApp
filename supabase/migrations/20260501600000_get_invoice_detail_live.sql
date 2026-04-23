-- =====================================================================
-- Invoice detail helper for the KPI drilldown invoice popup
--
-- Why this migration exists
-- -------------------------
-- The KPI underlying-rows tables (sales-line KPIs: revenue,
-- assistant_utilisation_ratio) now expose an Invoice Number column and
-- a per-row "View invoice" action that opens a popup with the full set
-- of lines on that invoice. This RPC backs that popup.
--
-- Why a dedicated RPC, not PostgREST on the view
-- ----------------------------------------------
-- public.v_sales_transactions_enriched is locked down in
-- 20260413170000_lock_down_reporting_views; non-elevated users (stylist
-- / assistant) cannot read it directly. The existing KPI drilldown
-- pipeline solves this with `public.get_kpi_drilldown_live` as
-- SECURITY DEFINER. This function mirrors that pattern: it returns
-- every line on an invoice tuple as postgres, trusting auth.uid() to
-- be authenticated (GRANT is limited to `authenticated`).
--
-- Key shape
-- ---------
-- An invoice is keyed by the (invoice, location_id, sale_date) tuple.
-- A raw `invoice` string alone is not necessarily unique across
-- locations or days, so the caller passes the full tuple copied
-- verbatim from the drilldown row's raw_payload. If `p_sale_date` is
-- NULL we fall back to the invoice+location pair — this keeps the RPC
-- usable if a caller only has two of the three identifiers.
--
-- No KPI math. No impact on snapshots or drilldown RPCs. Pure read.
-- =====================================================================


CREATE OR REPLACE FUNCTION public.get_invoice_detail_live(
  p_invoice     text,
  p_location_id uuid DEFAULT NULL,
  p_sale_date   date DEFAULT NULL
)
RETURNS TABLE (
  invoice                           text,
  sale_date                         date,
  sale_datetime                     timestamptz,
  location_id                       uuid,
  customer_name                     text,
  product_service_name              text,
  product_type_actual               text,
  price_ex_gst                      numeric,
  commission_owner_candidate_id     uuid,
  commission_owner_candidate_name   text,
  staff_work_id                     uuid,
  staff_work_name                   text,
  staff_work_display_name           text,
  staff_work_full_name              text,
  staff_work_primary_role           text,
  assistant_redirect_candidate      boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  SELECT
    e.invoice,
    e.sale_date,
    e.sale_datetime,
    e.location_id,
    e.customer_name,
    e.product_service_name,
    e.product_type_actual,
    e.price_ex_gst,
    e.commission_owner_candidate_id,
    e.commission_owner_candidate_name,
    e.staff_work_id,
    e.staff_work_name,
    e.staff_work_display_name,
    e.staff_work_full_name,
    e.staff_work_primary_role,
    e.assistant_redirect_candidate
  FROM public.v_sales_transactions_enriched e
  WHERE e.invoice = p_invoice
    AND (p_location_id IS NULL OR e.location_id = p_location_id)
    AND (p_sale_date   IS NULL OR e.sale_date   = p_sale_date)
  ORDER BY e.sale_datetime NULLS LAST, e.price_ex_gst DESC NULLS LAST;
$fn$;

ALTER FUNCTION public.get_invoice_detail_live(text, uuid, date) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_invoice_detail_live(text, uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_invoice_detail_live(text, uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_invoice_detail_live(text, uuid, date) TO service_role;

COMMENT ON FUNCTION public.get_invoice_detail_live(text, uuid, date) IS
'Return every line on an invoice tuple (invoice, location_id, sale_date) from public.v_sales_transactions_enriched. SECURITY DEFINER so non-elevated (stylist / assistant) callers who can see an invoice through get_kpi_drilldown_live can also open its detail popup on the KPI page. Pure read; no KPI math.';
