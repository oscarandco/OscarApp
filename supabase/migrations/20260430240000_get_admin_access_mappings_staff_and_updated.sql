-- Full admin list row: mapping id, staff join for labels, and updated_at for the table UI.
-- Return type changes: drop and recreate; restore grants.

DROP FUNCTION IF EXISTS public.get_admin_access_mappings();

CREATE OR REPLACE FUNCTION public.get_admin_access_mappings()
RETURNS TABLE (
  mapping_id uuid,
  user_id uuid,
  email text,
  staff_member_id uuid,
  staff_display_name text,
  staff_full_name text,
  staff_name text,
  access_role text,
  is_active boolean,
  created_at timestamp with time zone,
  updated_at timestamp with time zone
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  SELECT
    sma.id AS mapping_id,
    sma.user_id,
    COALESCE(au.email::text, '') AS email,
    sma.staff_member_id,
    NULLIF(trim(COALESCE(sm.display_name::text, '')), '') AS staff_display_name,
    NULLIF(trim(COALESCE(sm.full_name::text, '')), '') AS staff_full_name,
    COALESCE(
      NULLIF(trim(COALESCE(sm.display_name::text, '')), ''),
      NULLIF(trim(COALESCE(sm.full_name::text, '')), '')
    ) AS staff_name,
    sma.access_role,
    sma.is_active,
    sma.created_at,
    sma.updated_at
  FROM public.staff_member_user_access sma
  LEFT JOIN auth.users au ON au.id = sma.user_id
  LEFT JOIN public.staff_members sm ON sm.id = sma.staff_member_id
  WHERE private.user_has_elevated_access()
  ORDER BY sma.created_at DESC;
$$;

ALTER FUNCTION public.get_admin_access_mappings() OWNER TO postgres;

REVOKE ALL ON FUNCTION public.get_admin_access_mappings() FROM PUBLIC;
GRANT ALL ON FUNCTION public.get_admin_access_mappings() TO anon;
GRANT ALL ON FUNCTION public.get_admin_access_mappings() TO authenticated;
GRANT ALL ON FUNCTION public.get_admin_access_mappings() TO service_role;
