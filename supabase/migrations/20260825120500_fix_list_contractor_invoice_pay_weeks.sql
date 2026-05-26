-- Bugfix: list_contractor_invoice_pay_weeks() was raising
--   ERROR: column reference "pay_week_start" is ambiguous
-- at runtime because the function declares
--   RETURNS TABLE (pay_week_start date, pay_week_end date)
-- (which creates implicit OUT parameters) and then the body references the
-- same names unqualified in the inner UNION SELECTs and outer ORDER BY.
-- The new body fully qualifies every column reference via the `u` subquery
-- alias so the OUT param ↔ subquery column ambiguity goes away. No behaviour
-- change — same return shape, same rows, same ordering.

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
  SELECT u.pay_week_start, u.pay_week_end
  FROM (
    SELECT DISTINCT
      s.pay_week_start AS pay_week_start,
      s.pay_week_end   AS pay_week_end
    FROM public.v_admin_payroll_summary_weekly s
    UNION
    SELECT DISTINCT
      ci.pay_week_start AS pay_week_start,
      ci.pay_week_end   AS pay_week_end
    FROM public.contractor_invoices ci
  ) AS u
  ORDER BY u.pay_week_start DESC;
END;
$$;

ALTER FUNCTION public.list_contractor_invoice_pay_weeks() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.list_contractor_invoice_pay_weeks() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_contractor_invoice_pay_weeks() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_contractor_invoice_pay_weeks() TO service_role;
