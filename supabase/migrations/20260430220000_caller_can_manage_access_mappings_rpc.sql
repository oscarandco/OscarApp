-- Expose access-mapping admin check to authenticated callers (e.g. Edge Functions with user JWT).
-- Implementation stays in private.user_can_manage_access_mappings(); do not trust client role claims alone.

CREATE OR REPLACE FUNCTION public.caller_can_manage_access_mappings()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  SELECT private.user_can_manage_access_mappings();
$$;

ALTER FUNCTION public.caller_can_manage_access_mappings() OWNER TO postgres;

REVOKE ALL ON FUNCTION public.caller_can_manage_access_mappings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.caller_can_manage_access_mappings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.caller_can_manage_access_mappings() TO service_role;
