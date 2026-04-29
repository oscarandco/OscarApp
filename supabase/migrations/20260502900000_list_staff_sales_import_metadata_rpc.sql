-- Live first/last sale metadata for Staff Admin (per staff_member), derived from
-- current sales_transactions + v_sales_transactions_powerbi_parity (for
-- existing_staff_paid_name / staff_paid_name_derived). Elevated callers only.

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
  WITH tx AS (
    SELECT
      st.id AS tx_id,
      st.sale_date::date AS sale_day,
      NULLIF(TRIM(BOTH FROM COALESCE(l.name, '')), '') AS location_name,
      st.staff_commission_id,
      st.staff_work_id,
      st.staff_paid_id,
      NULLIF(TRIM(BOTH FROM COALESCE(st.staff_commission_name, '')), '') AS scn,
      NULLIF(TRIM(BOTH FROM COALESCE(st.staff_work_name, '')), '') AS swn,
      NULLIF(TRIM(BOTH FROM COALESCE(st.staff_paid_name, '')), '') AS spn,
      NULLIF(TRIM(BOTH FROM COALESCE(p.existing_staff_paid_name, '')), '') AS espn,
      NULLIF(TRIM(BOTH FROM COALESCE(p.staff_paid_name_derived, '')), '') AS spnd
    FROM public.sales_transactions st
    LEFT JOIN public.locations l ON l.id = st.location_id
    LEFT JOIN public.v_sales_transactions_powerbi_parity p ON p.id = st.id
    WHERE st.sale_date IS NOT NULL
  ),
  fk_match AS (
    SELECT DISTINCT
      t.tx_id,
      v.sid AS staff_member_id
    FROM tx t
    CROSS JOIN LATERAL (
      VALUES (t.staff_commission_id), (t.staff_work_id), (t.staff_paid_id)
    ) AS v(sid)
    WHERE v.sid IS NOT NULL
  ),
  name_match AS (
    SELECT DISTINCT
      t.tx_id,
      sm.id AS staff_member_id
    FROM tx t
    JOIN public.staff_members sm ON (
      NULLIF(TRIM(BOTH FROM sm.display_name), '') IS NOT NULL
      AND (
        (t.scn IS NOT NULL AND lower(t.scn) = lower(TRIM(BOTH FROM sm.display_name)))
        OR (t.swn IS NOT NULL AND lower(t.swn) = lower(TRIM(BOTH FROM sm.display_name)))
        OR (t.spn IS NOT NULL AND lower(t.spn) = lower(TRIM(BOTH FROM sm.display_name)))
        OR (t.espn IS NOT NULL AND lower(t.espn) = lower(TRIM(BOTH FROM sm.display_name)))
        OR (t.spnd IS NOT NULL AND lower(t.spnd) = lower(TRIM(BOTH FROM sm.display_name)))
      )
    )
  ),
  matched AS (
    SELECT DISTINCT
      u.staff_member_id,
      t.sale_day,
      t.location_name
    FROM (
      SELECT tx_id, staff_member_id FROM fk_match
      UNION ALL
      SELECT tx_id, staff_member_id FROM name_match
    ) u
    JOIN tx t ON t.tx_id = u.tx_id
  ),
  bounds AS (
    SELECT
      staff_member_id,
      min(sale_day) AS first_seen_sale_date,
      max(sale_day) AS last_seen_sale_date
    FROM matched
    GROUP BY staff_member_id
  ),
  first_distinct AS (
    SELECT m.staff_member_id, m.location_name
    FROM matched m
    JOIN bounds b ON b.staff_member_id = m.staff_member_id
      AND m.sale_day = b.first_seen_sale_date
    WHERE m.location_name IS NOT NULL
  ),
  last_distinct AS (
    SELECT m.staff_member_id, m.location_name
    FROM matched m
    JOIN bounds b ON b.staff_member_id = m.staff_member_id
      AND m.sale_day = b.last_seen_sale_date
    WHERE m.location_name IS NOT NULL
  ),
  first_agg AS (
    SELECT
      staff_member_id,
      string_agg(loc, ', ' ORDER BY loc) AS first_seen_sale_location_names
    FROM (
      SELECT DISTINCT staff_member_id, location_name AS loc
      FROM first_distinct
    ) x
    GROUP BY staff_member_id
  ),
  last_agg AS (
    SELECT
      staff_member_id,
      string_agg(loc, ', ' ORDER BY loc) AS last_seen_sale_location_names
    FROM (
      SELECT DISTINCT staff_member_id, location_name AS loc
      FROM last_distinct
    ) y
    GROUP BY staff_member_id
  )
  SELECT
    sm.id AS staff_member_id,
    b.first_seen_sale_date,
    fa.first_seen_sale_location_names,
    b.last_seen_sale_date,
    la.last_seen_sale_location_names
  FROM public.staff_members sm
  LEFT JOIN bounds b ON b.staff_member_id = sm.id
  LEFT JOIN first_agg fa ON fa.staff_member_id = sm.id
  LEFT JOIN last_agg la ON la.staff_member_id = sm.id;
END;
$fn$;

ALTER FUNCTION public.list_staff_sales_import_metadata() OWNER TO postgres;

COMMENT ON FUNCTION public.list_staff_sales_import_metadata() IS
  'Elevated-only: first/last sale_date and location names from live sales, matched by staff UUIDs on lines and by case-insensitive Kitomba display_name on staff text fields.';

REVOKE ALL ON FUNCTION public.list_staff_sales_import_metadata() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_staff_sales_import_metadata() TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_staff_sales_import_metadata() TO service_role;
