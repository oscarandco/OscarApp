-- Scalar FTE lookup for KPI card display normalisation when an admin or
-- manager views Staff → {member}. Mirrors get_my_fte() auth: stylists /
-- assistants only for their own id; elevated roles for any staff id.

CREATE OR REPLACE FUNCTION public.get_staff_fte_for_kpi_display(
  p_staff_member_id uuid
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $fn$
DECLARE
  v_role text;
  v_self uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  IF p_staff_member_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_role := private.kpi_caller_access_role();
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'no active access mapping for caller'
      USING ERRCODE = '42501';
  END IF;

  IF v_role IN ('stylist', 'assistant') THEN
    v_self := private.kpi_caller_staff_member_id();
    IF v_self IS NULL OR p_staff_member_id IS DISTINCT FROM v_self THEN
      RAISE EXCEPTION 'not authorized'
        USING ERRCODE = '42501';
    END IF;
  ELSIF v_role NOT IN ('admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'not authorized'
      USING ERRCODE = '42501';
  END IF;

  RETURN (
    SELECT sm.fte
    FROM public.staff_members sm
    WHERE sm.id = p_staff_member_id
    LIMIT 1
  );
END;
$fn$;

ALTER FUNCTION public.get_staff_fte_for_kpi_display(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_staff_fte_for_kpi_display(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_staff_fte_for_kpi_display(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_staff_fte_for_kpi_display(uuid) TO service_role;

COMMENT ON FUNCTION public.get_staff_fte_for_kpi_display(uuid) IS
  'Returns staff_members.fte for KPI card FTE normalisation. Stylists/assistants: own staff id only. Admin/manager/superadmin: any id.';
