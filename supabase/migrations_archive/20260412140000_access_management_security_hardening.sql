-- Hardening for admin access management: unique user mapping, RPC grants, duplicate-safe insert,
-- minimal auth user search projection.

-- One mapping per Supabase user (MVP). If this fails, remove duplicate user_id rows first.
CREATE UNIQUE INDEX IF NOT EXISTS staff_member_user_access_one_per_user
  ON public.staff_member_user_access (user_id);

-- Tighten default grants: SECURITY DEFINER RPCs should not be broadly executable.
REVOKE ALL ON FUNCTION public.get_admin_access_mappings() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.search_staff_members(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.search_auth_users(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_access_mapping(uuid, uuid, text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_access_mapping(uuid, uuid, text, boolean) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_admin_access_mappings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_staff_members(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_auth_users(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_access_mapping(uuid, uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_access_mapping(uuid, uuid, text, boolean) TO authenticated;

-- Only user_id + email from auth.users (no phone, metadata, timestamps, etc.).
CREATE OR REPLACE FUNCTION public.search_auth_users(p_search text DEFAULT NULL)
RETURNS TABLE (
  user_id uuid,
  email text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
  SELECT
    u.id AS user_id,
    COALESCE(u.email::text, '') AS email
  FROM auth.users AS u
  WHERE (SELECT private.user_has_elevated_access())
    AND COALESCE(u.email, '') <> ''
    AND NOT EXISTS (
      SELECT 1
      FROM public.staff_member_user_access AS m
      WHERE m.user_id = u.id
    )
    AND (
      p_search IS NULL
      OR length(trim(p_search)) = 0
      OR u.email::text ILIKE '%' || trim(p_search) || '%'
    )
  ORDER BY u.email
  LIMIT 100;
$$;

-- Race-safe: unique index + explicit duplicate check; unique_violation maps to a clear message.
CREATE OR REPLACE FUNCTION public.create_access_mapping(
  p_user_id uuid,
  p_staff_member_id uuid,
  p_access_role text,
  p_is_active boolean DEFAULT true
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT (SELECT private.user_can_manage_access_mappings()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_user_id IS NULL OR p_staff_member_id IS NULL OR p_access_role IS NULL OR trim(p_access_role) = '' THEN
    RAISE EXCEPTION 'invalid arguments';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM auth.users AS u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.staff_members AS s WHERE s.id = p_staff_member_id) THEN
    RAISE EXCEPTION 'staff member not found';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.staff_member_user_access AS x
    WHERE x.user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'access mapping already exists for this user';
  END IF;

  INSERT INTO public.staff_member_user_access (
    user_id,
    staff_member_id,
    access_role,
    is_active,
    created_at,
    updated_at
  )
  VALUES (
    p_user_id,
    p_staff_member_id,
    trim(p_access_role),
    COALESCE(p_is_active, true),
    now(),
    now()
  )
  RETURNING id INTO v_id;

  RETURN v_id;
EXCEPTION
  WHEN unique_violation THEN
    RAISE EXCEPTION 'access mapping already exists for this user'
      USING ERRCODE = '23505';
END;
$$;

REVOKE ALL ON FUNCTION public.search_auth_users(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_auth_users(text) TO authenticated;

REVOKE ALL ON FUNCTION public.create_access_mapping(uuid, uuid, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_access_mapping(uuid, uuid, text, boolean) TO authenticated;
