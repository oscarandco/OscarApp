-- Configurable per-role page access (sidebar + route guards). Seeded to match
-- the historical hardcoded matrix in the app. Writes are admin-only via RPC.

CREATE TABLE public.role_page_permissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  page_id text NOT NULL,
  role_key text NOT NULL,
  access_level text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT role_page_permissions_page_id_check CHECK (
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
      'role_permissions'
    )
  ),
  CONSTRAINT role_page_permissions_role_key_check CHECK (
    role_key IN ('assistant', 'stylist', 'manager', 'admin')
  ),
  CONSTRAINT role_page_permissions_access_level_check CHECK (
    access_level IN ('none', 'view', 'full')
  ),
  CONSTRAINT role_page_permissions_page_role_unique UNIQUE (page_id, role_key)
);

ALTER TABLE public.role_page_permissions OWNER TO postgres;

COMMENT ON TABLE public.role_page_permissions IS
  'Per-role page visibility / mutation level for the staff app. Consumed via get_role_page_permissions; '
  'mutations only through update_role_page_permission (admin).';

ALTER TABLE public.role_page_permissions ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.role_page_permissions FROM PUBLIC;
REVOKE ALL ON TABLE public.role_page_permissions FROM authenticated;

-- Seed: historical defaults + role_permissions (admin-only Configuration page).
INSERT INTO public.role_page_permissions (page_id, role_key, access_level)
SELECT x.page_id, x.role_key, x.access_level
FROM (
  VALUES
    ('my_payroll', 'assistant', 'full'),
    ('my_payroll', 'stylist', 'full'),
    ('my_payroll', 'manager', 'full'),
    ('my_payroll', 'admin', 'full'),
    ('guest_quote', 'assistant', 'full'),
    ('guest_quote', 'stylist', 'full'),
    ('guest_quote', 'manager', 'full'),
    ('guest_quote', 'admin', 'full'),
    ('previous_quotes', 'assistant', 'full'),
    ('previous_quotes', 'stylist', 'full'),
    ('previous_quotes', 'manager', 'full'),
    ('previous_quotes', 'admin', 'full'),
    ('kpi_dashboard', 'assistant', 'full'),
    ('kpi_dashboard', 'stylist', 'full'),
    ('kpi_dashboard', 'manager', 'full'),
    ('kpi_dashboard', 'admin', 'full'),
    ('weekly_payroll', 'assistant', 'none'),
    ('weekly_payroll', 'stylist', 'none'),
    ('weekly_payroll', 'manager', 'none'),
    ('weekly_payroll', 'admin', 'full'),
    ('commission_breakdown', 'assistant', 'none'),
    ('commission_breakdown', 'stylist', 'none'),
    ('commission_breakdown', 'manager', 'none'),
    ('commission_breakdown', 'admin', 'full'),
    ('imports', 'assistant', 'none'),
    ('imports', 'stylist', 'none'),
    ('imports', 'manager', 'full'),
    ('imports', 'admin', 'full'),
    ('staff', 'assistant', 'none'),
    ('staff', 'stylist', 'none'),
    ('staff', 'manager', 'none'),
    ('staff', 'admin', 'full'),
    ('products', 'assistant', 'none'),
    ('products', 'stylist', 'none'),
    ('products', 'manager', 'none'),
    ('products', 'admin', 'full'),
    ('quotes', 'assistant', 'none'),
    ('quotes', 'stylist', 'none'),
    ('quotes', 'manager', 'none'),
    ('quotes', 'admin', 'full'),
    ('remuneration', 'assistant', 'none'),
    ('remuneration', 'stylist', 'none'),
    ('remuneration', 'manager', 'none'),
    ('remuneration', 'admin', 'full'),
    ('access', 'assistant', 'none'),
    ('access', 'stylist', 'none'),
    ('access', 'manager', 'view'),
    ('access', 'admin', 'full'),
    ('role_permissions', 'assistant', 'none'),
    ('role_permissions', 'stylist', 'none'),
    ('role_permissions', 'manager', 'none'),
    ('role_permissions', 'admin', 'full')
) AS x(page_id, role_key, access_level)
ON CONFLICT (page_id, role_key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.get_role_page_permissions()
RETURNS TABLE (
  page_id text,
  role_key text,
  access_level text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
  SELECT
    r.page_id::text,
    r.role_key::text,
    r.access_level::text
  FROM public.role_page_permissions r
  WHERE auth.uid() IS NOT NULL
  ORDER BY r.page_id, r.role_key;
$$;

ALTER FUNCTION public.get_role_page_permissions() OWNER TO postgres;

COMMENT ON FUNCTION public.get_role_page_permissions() IS
  'Returns all role/page permission rows. Any authenticated user may call — matrix drives routing for every role.';

REVOKE ALL ON FUNCTION public.get_role_page_permissions() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_role_page_permissions() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_role_page_permissions() TO service_role;

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

  IF v_norm_role NOT IN ('assistant', 'stylist', 'manager', 'admin') THEN
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

  -- Prevent admin lockout from this configuration surface.
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

COMMENT ON FUNCTION public.update_role_page_permission(text, text, text) IS
  'Upserts one role/page permission. Admin-only (private.user_can_manage_access_mappings). Enforces admin safety rules.';

REVOKE ALL ON FUNCTION public.update_role_page_permission(text, text, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_role_page_permission(text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_role_page_permission(text, text, text) TO service_role;
