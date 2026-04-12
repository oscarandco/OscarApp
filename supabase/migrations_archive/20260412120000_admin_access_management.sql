-- Admin access management RPCs — link Supabase Auth users to staff via public.staff_member_user_access
--
-- Assumptions (adjust JOINs if your schema differs):
-- - public.staff_member_user_access has at least:
--     id uuid PK, user_id uuid, staff_member_id uuid, access_role text, is_active boolean,
--     created_at timestamptz, updated_at timestamptz
-- - public.staff_members has id uuid PK and name columns used below (display_name, full_name).
-- - One mapping per auth user: enforced in DB by migration `20260412140000_access_management_security_hardening.sql`
--   (`staff_member_user_access_one_per_user` unique index) plus application checks.

CREATE SCHEMA IF NOT EXISTS private;

-- Elevated: admin, superadmin, manager (matches app RequireAdminAccess / normalizeAccessProfile)
CREATE OR REPLACE FUNCTION private.user_has_elevated_access()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff_member_user_access a
    WHERE a.user_id = auth.uid()
      AND COALESCE(a.is_active, false) = true
      AND lower(trim(COALESCE(a.access_role, ''))) IN ('admin', 'superadmin', 'manager')
  );
$$;

-- Writes: admin or superadmin only (stricter than elevated)
CREATE OR REPLACE FUNCTION private.user_can_manage_access_mappings()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff_member_user_access a
    WHERE a.user_id = auth.uid()
      AND COALESCE(a.is_active, false) = true
      AND lower(trim(COALESCE(a.access_role, ''))) IN ('admin', 'superadmin')
  );
$$;

CREATE OR REPLACE FUNCTION public.get_admin_access_mappings()
RETURNS TABLE (
  mapping_id uuid,
  user_id uuid,
  email text,
  staff_member_id uuid,
  staff_display_name text,
  staff_full_name text,
  access_role text,
  is_active boolean,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $$
  SELECT
    smua.id AS mapping_id,
    smua.user_id,
    COALESCE(au.email::text, '') AS email,
    smua.staff_member_id,
    NULLIF(trim(COALESCE(sm.display_name::text, '')), '') AS staff_display_name,
    NULLIF(trim(COALESCE(sm.full_name::text, '')), '') AS staff_full_name,
    smua.access_role,
    COALESCE(smua.is_active, false) AS is_active,
    smua.created_at,
    smua.updated_at
  FROM public.staff_member_user_access smua
  LEFT JOIN auth.users au ON au.id = smua.user_id
  LEFT JOIN public.staff_members sm ON sm.id = smua.staff_member_id
  WHERE (SELECT private.user_has_elevated_access())
  ORDER BY smua.updated_at DESC NULLS LAST, smua.created_at DESC NULLS LAST;
$$;

CREATE OR REPLACE FUNCTION public.search_staff_members(p_search text DEFAULT NULL)
RETURNS TABLE (
  staff_member_id uuid,
  display_name text,
  full_name text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT
    sm.id AS staff_member_id,
    COALESCE(NULLIF(trim(sm.display_name::text), ''), '')::text AS display_name,
    COALESCE(NULLIF(trim(sm.full_name::text), ''), '')::text AS full_name
  FROM public.staff_members sm
  WHERE (SELECT private.user_has_elevated_access())
    AND (
      p_search IS NULL
      OR length(trim(p_search)) = 0
      OR COALESCE(sm.display_name::text, '') ILIKE '%' || trim(p_search) || '%'
      OR COALESCE(sm.full_name::text, '') ILIKE '%' || trim(p_search) || '%'
    )
  ORDER BY sm.display_name NULLS LAST, sm.full_name NULLS LAST
  LIMIT 100;
$$;

-- Lists auth users for picker. Requires SECURITY DEFINER to read auth.users (not exposed to PostgREST).
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
    u.id,
    COALESCE(u.email::text, '') AS email
  FROM auth.users u
  WHERE (SELECT private.user_has_elevated_access())
    AND COALESCE(u.email, '') <> ''
    -- Prefer users without a mapping yet (create form); edit flow does not use this search.
    AND NOT EXISTS (
      SELECT 1 FROM public.staff_member_user_access m WHERE m.user_id = u.id
    )
    AND (
      p_search IS NULL
      OR length(trim(p_search)) = 0
      OR u.email::text ILIKE '%' || trim(p_search) || '%'
    )
  ORDER BY u.email
  LIMIT 100;
$$;

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

  IF NOT EXISTS (SELECT 1 FROM auth.users u WHERE u.id = p_user_id) THEN
    RAISE EXCEPTION 'user not found';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.staff_members s WHERE s.id = p_staff_member_id) THEN
    RAISE EXCEPTION 'staff member not found';
  END IF;

  IF EXISTS (SELECT 1 FROM public.staff_member_user_access x WHERE x.user_id = p_user_id) THEN
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
END;
$$;

CREATE OR REPLACE FUNCTION public.update_access_mapping(
  p_mapping_id uuid,
  p_staff_member_id uuid,
  p_access_role text,
  p_is_active boolean
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF NOT (SELECT private.user_can_manage_access_mappings()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF p_mapping_id IS NULL OR p_staff_member_id IS NULL OR p_access_role IS NULL OR trim(p_access_role) = '' THEN
    RAISE EXCEPTION 'invalid arguments';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.staff_members s WHERE s.id = p_staff_member_id) THEN
    RAISE EXCEPTION 'staff member not found';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.staff_member_user_access m WHERE m.id = p_mapping_id
  ) THEN
    RAISE EXCEPTION 'mapping not found';
  END IF;

  UPDATE public.staff_member_user_access m
  SET
    staff_member_id = p_staff_member_id,
    access_role = trim(p_access_role),
    is_active = COALESCE(p_is_active, false),
    updated_at = now()
  WHERE m.id = p_mapping_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_access_mappings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_staff_members(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_auth_users(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.create_access_mapping(uuid, uuid, text, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_access_mapping(uuid, uuid, text, boolean) TO authenticated;
