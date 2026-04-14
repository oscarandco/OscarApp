-- Return staff_member_user_access primary key as mapping_id so the admin UI can call update_access_mapping(p_mapping_id, ...).
-- Return type changes: must drop and recreate; then restore grants.

DROP FUNCTION IF EXISTS public.get_admin_access_mappings();

CREATE OR REPLACE FUNCTION public.get_admin_access_mappings()
RETURNS TABLE (
  mapping_id uuid,
  user_id uuid,
  email text,
  access_role text,
  is_active boolean,
  created_at timestamp with time zone
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  SELECT
    sma.id AS mapping_id,
    sma.user_id,
    COALESCE(au.email::text, '') AS email,
    sma.access_role,
    sma.is_active,
    sma.created_at
  FROM public.staff_member_user_access sma
  LEFT JOIN auth.users au ON au.id = sma.user_id
  WHERE private.user_has_elevated_access()
  ORDER BY sma.created_at DESC;
$$;

ALTER FUNCTION public.get_admin_access_mappings() OWNER TO postgres;

REVOKE ALL ON FUNCTION public.get_admin_access_mappings() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_admin_access_mappings() TO anon;
GRANT ALL ON FUNCTION public.get_admin_access_mappings() TO authenticated;
GRANT ALL ON FUNCTION public.get_admin_access_mappings() TO service_role;
