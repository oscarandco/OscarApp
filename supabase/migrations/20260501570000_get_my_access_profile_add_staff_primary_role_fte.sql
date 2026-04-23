-- Extend public.get_my_access_profile() to also return the mapped
-- staff member's `primary_role` and `fte`. This is purely additive —
-- every existing column keeps the same name, type, and ordering, and
-- the same (auth.uid, is_active) filter is used. No access-control
-- changes.
--
-- Consumers:
--   - The desktop header identity block wants to show
--     "Jarod (adam@rada.co.nz)" on line 1 and
--     "Senior Stylist (Role: Stylist/1.0 FTE)" on line 2.
--   - Neither value is currently exposed via a client-facing RPC
--     because `staff_members` is RLS-locked to elevated callers.
--
-- Changing the return shape means we must DROP + CREATE rather than
-- CREATE OR REPLACE (Postgres does not allow signature changes in
-- place). `get_my_access_profile` is only called from the frontend
-- bootstrap path, so a brief deploy-window gap is acceptable, and
-- the new shape is a strict superset of the old one.

DROP FUNCTION IF EXISTS public.get_my_access_profile();

CREATE OR REPLACE FUNCTION public.get_my_access_profile()
RETURNS TABLE (
  user_id uuid,
  email text,
  staff_member_id uuid,
  staff_display_name text,
  staff_full_name text,
  staff_primary_role text,
  staff_fte numeric,
  access_role text,
  is_active boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT
    v.user_id,
    v.email,
    v.staff_member_id,
    v.staff_display_name,
    v.staff_full_name,
    sm.primary_role AS staff_primary_role,
    sm.fte          AS staff_fte,
    v.access_role,
    v.is_active
  FROM public.v_admin_user_access_overview v
  LEFT JOIN public.staff_members sm ON sm.id = v.staff_member_id
  WHERE v.user_id = auth.uid()
    AND v.is_active = true
  ORDER BY v.staff_full_name NULLS LAST
  LIMIT 1
$$;

COMMENT ON FUNCTION public.get_my_access_profile() IS
  'Access-profile row for the current auth user. Returns user_id, email, mapped staff identity (staff_member_id, display_name, full_name, primary_role, fte), and access_role / is_active. SECURITY DEFINER wraps the staff_members RLS so stylist/assistant callers can read their own staff metadata without being granted SELECT on the table.';

GRANT EXECUTE ON FUNCTION public.get_my_access_profile() TO authenticated;
