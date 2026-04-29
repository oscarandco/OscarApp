-- Elevated-only delete for `staff_members` via SECURITY DEFINER RPC.
--
-- Direct DELETE on public.staff_members is not granted to authenticated
-- (see 20260430290000_staff_configuration_access.sql). Deletes run
-- through this function, which enforces the same elevated rule as
-- staff insert/update policies: private.user_has_elevated_access().
--
-- Dependent rows (ON DELETE RESTRICT elsewhere, or no ON DELETE on
-- staff_member_user_access) are removed in a fixed order inside one
-- transaction. saved_quotes.stylist_staff_member_id uses ON DELETE SET
-- NULL on the FK, so no explicit update is required there.

CREATE OR REPLACE FUNCTION public.delete_staff_member_admin(p_staff_member_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_user_id  uuid;
  v_elevated boolean;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'delete_staff_member_admin: not authorized'
      USING ERRCODE = '28000';
  END IF;

  IF p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'delete_staff_member_admin: staff not found'
      USING ERRCODE = 'P0002';
  END IF;

  v_elevated := COALESCE((SELECT private.user_has_elevated_access()), false);
  IF NOT v_elevated THEN
    RAISE EXCEPTION 'delete_staff_member_admin: staff not found'
      USING ERRCODE = 'P0002';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.staff_members WHERE id = p_staff_member_id) THEN
    RAISE EXCEPTION 'delete_staff_member_admin: staff not found'
      USING ERRCODE = 'P0002';
  END IF;

  DELETE FROM public.kpi_monthly_values
  WHERE staff_member_id = p_staff_member_id;

  DELETE FROM public.kpi_targets
  WHERE staff_member_id = p_staff_member_id;

  DELETE FROM public.kpi_manual_inputs
  WHERE staff_member_id = p_staff_member_id;

  DELETE FROM public.kpi_upload_rows
  WHERE staff_member_id = p_staff_member_id;

  DELETE FROM public.staff_capacity_monthly
  WHERE staff_member_id = p_staff_member_id;

  DELETE FROM public.staff_member_user_access
  WHERE staff_member_id = p_staff_member_id;

  DELETE FROM public.staff_members
  WHERE id = p_staff_member_id;
END;
$fn$;

ALTER FUNCTION public.delete_staff_member_admin(uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.delete_staff_member_admin(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_staff_member_admin(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_staff_member_admin(uuid) TO service_role;
