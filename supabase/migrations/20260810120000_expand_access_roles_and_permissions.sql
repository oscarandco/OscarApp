-- Add reception + UAT access roles, expand role_page_permissions, seed defaults
-- (ON CONFLICT DO NOTHING — never overwrites existing rows).

-- ---------------------------------------------------------------------------
-- 1) staff_member_user_access.access_role
-- ---------------------------------------------------------------------------
ALTER TABLE public.staff_member_user_access
  DROP CONSTRAINT IF EXISTS staff_member_user_access_role_check;

ALTER TABLE public.staff_member_user_access
  ADD CONSTRAINT staff_member_user_access_role_check
  CHECK (
    access_role = ANY (
      ARRAY[
        'stylist'::text,
        'assistant'::text,
        'reception'::text,
        'manager'::text,
        'assistant_uat'::text,
        'stylist_uat'::text,
        'reception_uat'::text,
        'manager_uat'::text,
        'admin'::text,
        'superadmin'::text
      ]
    )
  );

-- ---------------------------------------------------------------------------
-- 2) role_page_permissions.role_key
-- ---------------------------------------------------------------------------
ALTER TABLE public.role_page_permissions
  DROP CONSTRAINT IF EXISTS role_page_permissions_role_key_check;

ALTER TABLE public.role_page_permissions
  ADD CONSTRAINT role_page_permissions_role_key_check
  CHECK (
    role_key = ANY (
      ARRAY[
        'assistant'::text,
        'stylist'::text,
        'reception'::text,
        'manager'::text,
        'assistant_uat'::text,
        'stylist_uat'::text,
        'reception_uat'::text,
        'manager_uat'::text,
        'admin'::text
      ]
    )
  );

-- ---------------------------------------------------------------------------
-- 3) Seed defaults for new role keys (65 rows) — do not touch existing cells
-- ---------------------------------------------------------------------------
INSERT INTO public.role_page_permissions (page_id, role_key, access_level)
VALUES
  -- reception (matches app fallback matrix)
  ('my_payroll', 'reception', 'none'),
  ('guest_quote', 'reception', 'full'),
  ('previous_quotes', 'reception', 'full'),
  ('kpi_dashboard', 'reception', 'none'),
  ('weekly_payroll', 'reception', 'none'),
  ('commission_breakdown', 'reception', 'none'),
  ('imports', 'reception', 'none'),
  ('staff', 'reception', 'none'),
  ('products', 'reception', 'none'),
  ('quotes', 'reception', 'none'),
  ('remuneration', 'reception', 'none'),
  ('access', 'reception', 'none'),
  ('role_permissions', 'reception', 'none'),
  -- assistant_uat (same as assistant)
  ('my_payroll', 'assistant_uat', 'full'),
  ('guest_quote', 'assistant_uat', 'full'),
  ('previous_quotes', 'assistant_uat', 'full'),
  ('kpi_dashboard', 'assistant_uat', 'full'),
  ('weekly_payroll', 'assistant_uat', 'none'),
  ('commission_breakdown', 'assistant_uat', 'none'),
  ('imports', 'assistant_uat', 'none'),
  ('staff', 'assistant_uat', 'none'),
  ('products', 'assistant_uat', 'none'),
  ('quotes', 'assistant_uat', 'none'),
  ('remuneration', 'assistant_uat', 'none'),
  ('access', 'assistant_uat', 'none'),
  ('role_permissions', 'assistant_uat', 'none'),
  -- stylist_uat (same as stylist / assistant in legacy seed)
  ('my_payroll', 'stylist_uat', 'full'),
  ('guest_quote', 'stylist_uat', 'full'),
  ('previous_quotes', 'stylist_uat', 'full'),
  ('kpi_dashboard', 'stylist_uat', 'full'),
  ('weekly_payroll', 'stylist_uat', 'none'),
  ('commission_breakdown', 'stylist_uat', 'none'),
  ('imports', 'stylist_uat', 'none'),
  ('staff', 'stylist_uat', 'none'),
  ('products', 'stylist_uat', 'none'),
  ('quotes', 'stylist_uat', 'none'),
  ('remuneration', 'stylist_uat', 'none'),
  ('access', 'stylist_uat', 'none'),
  ('role_permissions', 'stylist_uat', 'none'),
  -- reception_uat (same as reception)
  ('my_payroll', 'reception_uat', 'none'),
  ('guest_quote', 'reception_uat', 'full'),
  ('previous_quotes', 'reception_uat', 'full'),
  ('kpi_dashboard', 'reception_uat', 'none'),
  ('weekly_payroll', 'reception_uat', 'none'),
  ('commission_breakdown', 'reception_uat', 'none'),
  ('imports', 'reception_uat', 'none'),
  ('staff', 'reception_uat', 'none'),
  ('products', 'reception_uat', 'none'),
  ('quotes', 'reception_uat', 'none'),
  ('remuneration', 'reception_uat', 'none'),
  ('access', 'reception_uat', 'none'),
  ('role_permissions', 'reception_uat', 'none'),
  -- manager_uat (same as manager)
  ('my_payroll', 'manager_uat', 'full'),
  ('guest_quote', 'manager_uat', 'full'),
  ('previous_quotes', 'manager_uat', 'full'),
  ('kpi_dashboard', 'manager_uat', 'full'),
  ('weekly_payroll', 'manager_uat', 'none'),
  ('commission_breakdown', 'manager_uat', 'none'),
  ('imports', 'manager_uat', 'full'),
  ('staff', 'manager_uat', 'none'),
  ('products', 'manager_uat', 'none'),
  ('quotes', 'manager_uat', 'none'),
  ('remuneration', 'manager_uat', 'none'),
  ('access', 'manager_uat', 'view'),
  ('role_permissions', 'manager_uat', 'none')
ON CONFLICT (page_id, role_key) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 4) Elevated access (imports, admin shell shortlinks): include manager_uat
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.user_has_elevated_access()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.staff_member_user_access
    WHERE user_id = auth.uid()
      AND is_active = true
      AND access_role IN ('admin', 'superadmin', 'manager', 'manager_uat')
  );
$$;

-- ---------------------------------------------------------------------------
-- 5) KPI caller helpers — deterministic ordering when multiple mappings exist
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.kpi_caller_access_role()
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  SELECT a.access_role
  FROM public.staff_member_user_access a
  WHERE a.user_id = auth.uid()
    AND a.is_active = true
  ORDER BY
    CASE a.access_role
      WHEN 'admin' THEN 1
      WHEN 'superadmin' THEN 1
      WHEN 'manager' THEN 2
      WHEN 'manager_uat' THEN 2
      WHEN 'stylist' THEN 3
      WHEN 'stylist_uat' THEN 3
      WHEN 'assistant' THEN 4
      WHEN 'assistant_uat' THEN 4
      WHEN 'reception' THEN 5
      WHEN 'reception_uat' THEN 5
      ELSE 9
    END
  LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION private.kpi_caller_staff_member_id()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'auth', 'pg_temp'
AS $$
  SELECT a.staff_member_id
  FROM public.staff_member_user_access a
  WHERE a.user_id = auth.uid()
    AND a.is_active = true
    AND a.staff_member_id IS NOT NULL
  ORDER BY
    CASE a.access_role
      WHEN 'admin' THEN 1
      WHEN 'superadmin' THEN 1
      WHEN 'manager' THEN 2
      WHEN 'manager_uat' THEN 2
      WHEN 'stylist' THEN 3
      WHEN 'stylist_uat' THEN 3
      WHEN 'assistant' THEN 4
      WHEN 'assistant_uat' THEN 4
      WHEN 'reception' THEN 5
      WHEN 'reception_uat' THEN 5
      ELSE 9
    END
  LIMIT 1;
$$;

-- ---------------------------------------------------------------------------
-- 6) update_role_page_permission — validate expanded role_key set
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
    'role_permissions'
  ) THEN
    RAISE EXCEPTION 'Invalid page_id';
  END IF;

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
