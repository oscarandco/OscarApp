-- Server-enforced delete: only when no staff_members row references this plan by name (case-insensitive).

CREATE OR REPLACE FUNCTION public.admin_delete_remuneration_plan_if_unused(p_plan_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_plan_name text;
  v_count bigint;
BEGIN
  IF NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT rp.plan_name INTO v_plan_name
  FROM public.remuneration_plans rp
  WHERE rp.id = p_plan_id;

  IF v_plan_name IS NULL THEN
    RAISE EXCEPTION 'remuneration plan not found';
  END IF;

  SELECT count(*)::bigint INTO v_count
  FROM public.staff_members sm
  WHERE sm.remuneration_plan IS NOT NULL
    AND btrim(sm.remuneration_plan) <> ''
    AND lower(trim(sm.remuneration_plan)) = lower(trim(v_plan_name));

  IF v_count > 0 THEN
    RAISE EXCEPTION
      'Cannot delete this plan: % staff still assigned. Reassign them in Staff Configuration first.',
      v_count;
  END IF;

  DELETE FROM public.remuneration_plans WHERE id = p_plan_id;
END;
$$;

ALTER FUNCTION public.admin_delete_remuneration_plan_if_unused(uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.admin_delete_remuneration_plan_if_unused(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_delete_remuneration_plan_if_unused(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_remuneration_plan_if_unused(uuid) TO service_role;
