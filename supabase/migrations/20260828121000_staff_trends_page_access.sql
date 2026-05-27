-- Staff trends page access (20260828121000).
--
-- Adds a new admin reporting page id 'staff_trends' to the
-- role_page_permissions CHECK and the update_role_page_permission
-- allowlist, then seeds defaults that mirror 'commission_breakdown'
-- (admin full, every other role none).
--
-- The page itself is a read-only visualisation built on top of the
-- existing public.get_admin_payroll_summary_weekly() RPC and the
-- public.v_admin_payroll_summary_weekly view. No payroll, commission,
-- KPI, contractor-invoice, voucher, role / pay history, or Product
-- Configuration logic is touched.

-- ---------------------------------------------------------------------------
-- 1) Extend the role_page_permissions page_id CHECK constraint.
-- ---------------------------------------------------------------------------
ALTER TABLE public.role_page_permissions
  DROP CONSTRAINT IF EXISTS role_page_permissions_page_id_check;

ALTER TABLE public.role_page_permissions
  ADD CONSTRAINT role_page_permissions_page_id_check CHECK (
    page_id IN (
      'my_payroll',
      'guest_quote',
      'previous_quotes',
      'kpi_dashboard',
      'weekly_payroll',
      'commission_breakdown',
      'staff_trends',
      'imports',
      'staff',
      'products',
      'quotes',
      'remuneration',
      'access',
      'role_permissions',
      'contractor_invoices',
      'business_settings',
      'commission_guide'
    )
  );

-- ---------------------------------------------------------------------------
-- 2) Seed defaults: admin full, every other role none (mirrors
--    'commission_breakdown'). ON CONFLICT DO NOTHING so a customised
--    environment isn't overwritten.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_page_permissions (page_id, role_key, access_level)
VALUES
  ('staff_trends', 'assistant',      'none'),
  ('staff_trends', 'stylist',        'none'),
  ('staff_trends', 'reception',      'none'),
  ('staff_trends', 'manager',        'none'),
  ('staff_trends', 'assistant_uat',  'none'),
  ('staff_trends', 'stylist_uat',    'none'),
  ('staff_trends', 'reception_uat',  'none'),
  ('staff_trends', 'manager_uat',    'none'),
  ('staff_trends', 'admin',          'full')
ON CONFLICT (page_id, role_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) Expand update_role_page_permission's allowlist to include the new
--    page id (so it can be edited via the Role Permissions UI).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_role_page_permission(
  p_page_id text,
  p_role_key text,
  p_access_level text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_norm_page text;
  v_norm_role text;
  v_norm_level text;
  v_row public.role_page_permissions%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT (SELECT private.user_can_manage_access_mappings()) THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  v_norm_page  := lower(trim(COALESCE(p_page_id, '')));
  v_norm_role  := lower(trim(COALESCE(p_role_key, '')));
  v_norm_level := lower(trim(COALESCE(p_access_level, '')));

  IF v_norm_page = '' OR v_norm_role = '' OR v_norm_level = '' THEN
    RAISE EXCEPTION 'page_id, role_key, and access_level are required';
  END IF;

  IF v_norm_role NOT IN (
    'assistant','stylist','reception','manager',
    'assistant_uat','stylist_uat','reception_uat','manager_uat','admin'
  ) THEN
    RAISE EXCEPTION 'Invalid role_key';
  END IF;

  IF v_norm_level NOT IN ('none', 'view', 'full') THEN
    RAISE EXCEPTION 'Invalid access_level';
  END IF;

  IF v_norm_page NOT IN (
    'my_payroll','guest_quote','previous_quotes','kpi_dashboard',
    'weekly_payroll','commission_breakdown','staff_trends','imports','staff','products',
    'quotes','remuneration','access','role_permissions','contractor_invoices',
    'business_settings','commission_guide'
  ) THEN
    RAISE EXCEPTION 'Invalid page_id';
  END IF;

  -- Lockout guards (unchanged).
  IF v_norm_page = 'role_permissions' AND v_norm_role = 'admin' AND v_norm_level <> 'full' THEN
    RAISE EXCEPTION 'Admin must retain Full access to Role permissions';
  END IF;

  IF v_norm_page = 'access' AND v_norm_role = 'admin' AND v_norm_level = 'none' THEN
    RAISE EXCEPTION 'Admin must retain at least View access to Access';
  END IF;

  INSERT INTO public.role_page_permissions (page_id, role_key, access_level)
  VALUES (v_norm_page, v_norm_role, v_norm_level)
  ON CONFLICT (page_id, role_key)
  DO UPDATE SET access_level = EXCLUDED.access_level, updated_at = now()
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

ALTER FUNCTION public.update_role_page_permission(text, text, text) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.update_role_page_permission(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_role_page_permission(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_role_page_permission(text, text, text) TO service_role;

COMMENT ON FUNCTION public.update_role_page_permission(text, text, text) IS
  'Upserts one role_page_permissions row. Admin-only (via private.user_can_manage_access_mappings). '
  '20260828121000 added page id ''staff_trends'' to the allowlist.';
