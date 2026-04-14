-- Allow elevated users (manager/admin) to manage remuneration plans and rates via the app.
-- Staff table remains without direct client SELECT; use SECURITY DEFINER helpers for linkage.

GRANT SELECT, INSERT, UPDATE, DELETE ON public.remuneration_plans TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.remuneration_plan_rates TO authenticated;

CREATE POLICY "remuneration_plans_elevated_all"
  ON public.remuneration_plans
  FOR ALL
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()))
  WITH CHECK ((SELECT private.user_has_elevated_access()));

CREATE POLICY "remuneration_plan_rates_elevated_all"
  ON public.remuneration_plan_rates
  FOR ALL
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()))
  WITH CHECK ((SELECT private.user_has_elevated_access()));

-- Aggregated staff counts per plan (match keys with lower(trim(plan_name))).
CREATE OR REPLACE FUNCTION public.admin_remuneration_staff_counts()
RETURNS TABLE (plan_key text, staff_count bigint)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT lower(trim(sm.remuneration_plan)) AS plan_key,
         count(*)::bigint AS staff_count
  FROM public.staff_members sm
  WHERE sm.remuneration_plan IS NOT NULL
    AND btrim(sm.remuneration_plan) <> ''
    AND (SELECT private.user_has_elevated_access())
  GROUP BY lower(trim(sm.remuneration_plan));
$$;

ALTER FUNCTION public.admin_remuneration_staff_counts() OWNER TO postgres;

REVOKE ALL ON FUNCTION public.admin_remuneration_staff_counts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_remuneration_staff_counts() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_remuneration_staff_counts() TO service_role;

-- Staff rows linked to a plan name (read-only for admin UI).
CREATE OR REPLACE FUNCTION public.admin_staff_for_remuneration_plan(p_plan_name text)
RETURNS TABLE (
  staff_member_id uuid,
  display_name text,
  full_name text,
  is_active boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT s.id,
         s.display_name,
         s.full_name,
         s.is_active
  FROM public.staff_members s
  WHERE (SELECT private.user_has_elevated_access())
    AND p_plan_name IS NOT NULL
    AND btrim(p_plan_name) <> ''
    AND s.remuneration_plan IS NOT NULL
    AND lower(trim(s.remuneration_plan)) = lower(trim(p_plan_name))
  ORDER BY COALESCE(s.display_name, s.full_name, '');
$$;

ALTER FUNCTION public.admin_staff_for_remuneration_plan(text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.admin_staff_for_remuneration_plan(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_staff_for_remuneration_plan(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_staff_for_remuneration_plan(text) TO service_role;
