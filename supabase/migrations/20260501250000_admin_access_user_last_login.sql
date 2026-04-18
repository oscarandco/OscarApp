-- Surface auth.users.last_sign_in_at (and auth.users.created_at for the
-- "pending mapping" section) through the two SECURITY DEFINER RPCs that
-- drive the Access Management page. These fields live on auth.users,
-- which is not reachable directly from PostgREST for authenticated
-- callers, so the RPCs are the only way to get them to the UI.
--
-- Return types change, so we DROP + CREATE both functions and restore
-- the existing grants exactly as they were in the previous migrations
-- (see 20260430230000 / 20260430240000 for get_admin_access_mappings
-- and 20260412140000 for search_auth_users).

-- ── get_admin_access_mappings ──────────────────────────────────────────
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
  updated_at timestamp with time zone,
  last_sign_in_at timestamp with time zone
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
    sma.updated_at,
    au.last_sign_in_at
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

-- ── search_auth_users ──────────────────────────────────────────────────
-- Body is unchanged except that we additionally expose `created_at` (for
-- the "Users pending mapping" table's Created column) and
-- `last_sign_in_at` (for the Last login column). Filtering semantics
-- (elevated-access gate, non-empty email, not already mapped,
-- case-insensitive email ILIKE, 100-row cap) are preserved verbatim.
DROP FUNCTION IF EXISTS public.search_auth_users(text);

CREATE OR REPLACE FUNCTION public.search_auth_users(p_search text DEFAULT NULL)
RETURNS TABLE (
  user_id uuid,
  email text,
  created_at timestamp with time zone,
  last_sign_in_at timestamp with time zone
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  SELECT
    u.id AS user_id,
    COALESCE(u.email::text, '') AS email,
    u.created_at,
    u.last_sign_in_at
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

ALTER FUNCTION public.search_auth_users(text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.search_auth_users(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.search_auth_users(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_auth_users(text) TO service_role;
