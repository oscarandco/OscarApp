-- Optimise list_staff_sales_import_metadata: FK-only staff linkage on
-- sales_transactions (no parity view, no display_name scans). Same
-- RETURNS TABLE shape for Staff Admin.

CREATE OR REPLACE FUNCTION public.list_staff_sales_import_metadata()
RETURNS TABLE (
  staff_member_id uuid,
  first_seen_sale_date date,
  first_seen_sale_location_names text,
  last_seen_sale_date date,
  last_seen_sale_location_names text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'list_staff_sales_import_metadata: not authorized'
      USING ERRCODE = '28000';
  END IF;

  IF NOT COALESCE((SELECT private.user_has_elevated_access()), false) THEN
    RAISE EXCEPTION 'list_staff_sales_import_metadata: forbidden'
      USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
  WITH st AS (
    SELECT
      st_inner.id AS st_tx_id,
      st_inner.sale_date::date AS st_sale_day,
      NULLIF(
        TRIM(BOTH FROM COALESCE(l_inner.name, ''::text)),
        ''::text
      ) AS st_location_name,
      st_inner.staff_commission_id AS st_staff_commission_id,
      st_inner.staff_work_id AS st_staff_work_id,
      st_inner.staff_paid_id AS st_staff_paid_id
    FROM public.sales_transactions AS st_inner
    LEFT JOIN public.locations AS l_inner ON l_inner.id = st_inner.location_id
    WHERE st_inner.sale_date IS NOT NULL
  ),
  fk_expanded AS (
    SELECT DISTINCT
      s.st_tx_id,
      s.st_sale_day,
      s.st_location_name,
      v.matched_staff_member_id
    FROM st AS s
    CROSS JOIN LATERAL (
      VALUES
        (s.st_staff_commission_id),
        (s.st_staff_work_id),
        (s.st_staff_paid_id)
    ) AS v(matched_staff_member_id)
    WHERE v.matched_staff_member_id IS NOT NULL
  ),
  bounds AS (
    SELECT
      fe.matched_staff_member_id AS b_staff_id,
      min(fe.st_sale_day) AS b_first_seen_sale_date,
      max(fe.st_sale_day) AS b_last_seen_sale_date
    FROM fk_expanded AS fe
    GROUP BY fe.matched_staff_member_id
  ),
  first_loc AS (
    SELECT
      d.b_staff_id AS fl_staff_id,
      string_agg(d.loc, ', ' ORDER BY d.loc) AS fl_first_seen_sale_location_names
    FROM (
      SELECT DISTINCT
        fe.matched_staff_member_id AS b_staff_id,
        fe.st_location_name AS loc
      FROM fk_expanded AS fe
      INNER JOIN bounds AS b
        ON b.b_staff_id = fe.matched_staff_member_id
        AND fe.st_sale_day = b.b_first_seen_sale_date
      WHERE fe.st_location_name IS NOT NULL
    ) AS d
    GROUP BY d.b_staff_id
  ),
  last_loc AS (
    SELECT
      d2.b_staff_id AS ll_staff_id,
      string_agg(d2.loc, ', ' ORDER BY d2.loc) AS ll_last_seen_sale_location_names
    FROM (
      SELECT DISTINCT
        fe.matched_staff_member_id AS b_staff_id,
        fe.st_location_name AS loc
      FROM fk_expanded AS fe
      INNER JOIN bounds AS b
        ON b.b_staff_id = fe.matched_staff_member_id
        AND fe.st_sale_day = b.b_last_seen_sale_date
      WHERE fe.st_location_name IS NOT NULL
    ) AS d2
    GROUP BY d2.b_staff_id
  )
  SELECT
    sm.id,
    b.b_first_seen_sale_date,
    fl.fl_first_seen_sale_location_names,
    b.b_last_seen_sale_date,
    ll.ll_last_seen_sale_location_names
  FROM public.staff_members AS sm
  LEFT JOIN bounds AS b ON b.b_staff_id = sm.id
  LEFT JOIN first_loc AS fl ON fl.fl_staff_id = sm.id
  LEFT JOIN last_loc AS ll ON ll.ll_staff_id = sm.id;
END;
$fn$;

ALTER FUNCTION public.list_staff_sales_import_metadata() OWNER TO postgres;

COMMENT ON FUNCTION public.list_staff_sales_import_metadata() IS
  'Elevated-only: first/last sale_date and location names from sales_transactions, matched only via staff_commission_id, staff_work_id, and staff_paid_id (FK). One row per staff_member; nulls when no matching sales.';

REVOKE ALL ON FUNCTION public.list_staff_sales_import_metadata() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_staff_sales_import_metadata() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_staff_sales_import_metadata() TO service_role;
