-- Add two new page IDs (contractor_invoices, business_settings) to the role
-- permissions matrix and provide a private helper SECURITY DEFINER functions
-- can call to enforce per-page View/Full access from inside RPCs.

-- ---------------------------------------------------------------------------
-- 1) Extend the role_page_permissions page_id CHECK constraint
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
      'imports',
      'staff',
      'products',
      'quotes',
      'remuneration',
      'access',
      'role_permissions',
      'contractor_invoices',
      'business_settings'
    )
  );

-- ---------------------------------------------------------------------------
-- 2) Seed defaults for every existing role key. ON CONFLICT DO NOTHING so we
--    never overwrite an environment that has already been customised.
--    Default: admin = full; everyone else = none.
-- ---------------------------------------------------------------------------
INSERT INTO public.role_page_permissions (page_id, role_key, access_level)
VALUES
  ('contractor_invoices', 'assistant', 'none'),
  ('contractor_invoices', 'stylist', 'none'),
  ('contractor_invoices', 'reception', 'none'),
  ('contractor_invoices', 'manager', 'none'),
  ('contractor_invoices', 'assistant_uat', 'none'),
  ('contractor_invoices', 'stylist_uat', 'none'),
  ('contractor_invoices', 'reception_uat', 'none'),
  ('contractor_invoices', 'manager_uat', 'none'),
  ('contractor_invoices', 'admin', 'full'),
  ('business_settings', 'assistant', 'none'),
  ('business_settings', 'stylist', 'none'),
  ('business_settings', 'reception', 'none'),
  ('business_settings', 'manager', 'none'),
  ('business_settings', 'assistant_uat', 'none'),
  ('business_settings', 'stylist_uat', 'none'),
  ('business_settings', 'reception_uat', 'none'),
  ('business_settings', 'manager_uat', 'none'),
  ('business_settings', 'admin', 'full')
ON CONFLICT (page_id, role_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 3) Expand update_role_page_permission's allowlist (mirror the new page IDs)
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
    RAISE EXCEPTION 'Not authenticated'
      USING ERRCODE = '42501';
  END IF;

  IF NOT (SELECT private.user_can_manage_access_mappings()) THEN
    RAISE EXCEPTION 'Forbidden'
      USING ERRCODE = '42501';
  END IF;

  v_norm_page := lower(trim(COALESCE(p_page_id, '')));
  v_norm_role := lower(trim(COALESCE(p_role_key, '')));
  v_norm_level := lower(trim(COALESCE(p_access_level, '')));

  IF v_norm_page = '' OR v_norm_role = '' OR v_norm_level = '' THEN
    RAISE EXCEPTION 'page_id, role_key, and access_level are required';
  END IF;

  IF v_norm_role NOT IN (
    'assistant',
    'stylist',
    'reception',
    'manager',
    'assistant_uat',
    'stylist_uat',
    'reception_uat',
    'manager_uat',
    'admin'
  ) THEN
    RAISE EXCEPTION 'Invalid role_key';
  END IF;

  IF v_norm_level NOT IN ('none', 'view', 'full') THEN
    RAISE EXCEPTION 'Invalid access_level';
  END IF;

  IF v_norm_page NOT IN (
    'my_payroll',
    'guest_quote',
    'previous_quotes',
    'kpi_dashboard',
    'weekly_payroll',
    'commission_breakdown',
    'imports',
    'staff',
    'products',
    'quotes',
    'remuneration',
    'access',
    'role_permissions',
    'contractor_invoices',
    'business_settings'
  ) THEN
    RAISE EXCEPTION 'Invalid page_id';
  END IF;

  -- Lockout guards.
  IF v_norm_page = 'role_permissions' AND v_norm_role = 'admin' AND v_norm_level <> 'full' THEN
    RAISE EXCEPTION 'Admin must retain Full access to Role permissions';
  END IF;

  IF v_norm_page = 'access' AND v_norm_role = 'admin' AND v_norm_level = 'none' THEN
    RAISE EXCEPTION 'Admin must retain at least View access to Access';
  END IF;

  INSERT INTO public.role_page_permissions (page_id, role_key, access_level)
  VALUES (v_norm_page, v_norm_role, v_norm_level)
  ON CONFLICT (page_id, role_key)
  DO UPDATE SET
    access_level = EXCLUDED.access_level,
    updated_at = now()
  RETURNING * INTO v_row;

  RETURN to_jsonb(v_row);
END;
$$;

ALTER FUNCTION public.update_role_page_permission(text, text, text) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.update_role_page_permission(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_role_page_permission(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_role_page_permission(text, text, text) TO service_role;

-- ---------------------------------------------------------------------------
-- 4) Helper: private.user_has_page_access(p_page_id text, p_min_level text)
--    Returns true when the caller has at least p_min_level on p_page_id.
--    superadmin / admin always satisfy 'full'. Used by every new RPC below.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.user_has_page_access(
  p_page_id text,
  p_min_level text DEFAULT 'view'
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  WITH norm AS (
    SELECT
      lower(trim(COALESCE(p_page_id, ''))) AS page_id,
      CASE lower(trim(COALESCE(p_min_level, 'view')))
        WHEN 'full' THEN 2
        WHEN 'view' THEN 1
        ELSE 0
      END AS need_rank
  ),
  caller_roles AS (
    SELECT a.access_role
    FROM public.staff_member_user_access a
    WHERE a.user_id = auth.uid()
      AND a.is_active = true
  ),
  -- Superadmin / admin are always Full on every page.
  short_circuit AS (
    SELECT EXISTS (
      SELECT 1 FROM caller_roles
      WHERE access_role IN ('admin', 'superadmin')
    ) AS is_full_admin
  ),
  -- Otherwise look up the matrix.
  matrix_max AS (
    SELECT COALESCE(MAX(
      CASE r.access_level
        WHEN 'full' THEN 2
        WHEN 'view' THEN 1
        ELSE 0
      END
    ), 0) AS have_rank
    FROM public.role_page_permissions r
    JOIN caller_roles c ON c.access_role = r.role_key
    WHERE r.page_id = (SELECT page_id FROM norm)
  )
  SELECT
    (auth.uid() IS NOT NULL)
    AND (
      (SELECT is_full_admin FROM short_circuit)
      OR (SELECT have_rank FROM matrix_max) >= (SELECT need_rank FROM norm)
    );
$$;

ALTER FUNCTION private.user_has_page_access(text, text) OWNER TO postgres;

COMMENT ON FUNCTION private.user_has_page_access(text, text) IS
  'Server-side per-page permission probe for SECURITY DEFINER RPCs. '
  'Returns true when caller has at least p_min_level (none/view/full) on p_page_id. '
  'Admin/superadmin always satisfy full.';

REVOKE ALL ON FUNCTION private.user_has_page_access(text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.user_has_page_access(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION private.user_has_page_access(text, text) TO service_role;
