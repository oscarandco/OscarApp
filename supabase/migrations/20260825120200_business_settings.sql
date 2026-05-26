-- Business Settings (singleton): "buyer" details snapshotted onto every
-- contractor invoice. Backs /app/admin/business-settings and is required for
-- create_contractor_invoice (legal_business_name, address fields).

CREATE TABLE IF NOT EXISTS public.business_settings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  legal_business_name text NOT NULL DEFAULT '',
  trading_name text,
  street_address text NOT NULL DEFAULT '',
  suburb text NOT NULL DEFAULT '',
  city_postcode text NOT NULL DEFAULT '',
  email text,
  phone text,
  nzbn text,
  gst_number text,
  -- Singleton enforced by a unique row marker; only one row may have value 'singleton'.
  row_marker text NOT NULL DEFAULT 'singleton',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  CONSTRAINT business_settings_row_marker_singleton UNIQUE (row_marker)
);

ALTER TABLE public.business_settings OWNER TO postgres;

COMMENT ON TABLE public.business_settings IS
  'Buyer business details for buyer-created tax invoices. Singleton (enforced by row_marker UNIQUE). '
  'Snapshotted onto contractor_invoices on create.';

-- RLS: writes go through update_business_settings RPC; reads also go through RPC.
ALTER TABLE public.business_settings ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.business_settings FROM PUBLIC;
REVOKE ALL ON TABLE public.business_settings FROM authenticated;

-- Seed an empty singleton row so updates are simple upserts on a known id.
INSERT INTO public.business_settings (row_marker)
VALUES ('singleton')
ON CONFLICT (row_marker) DO NOTHING;

-- ---------------------------------------------------------------------------
-- updated_at trigger
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.business_settings_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.business_settings_set_updated_at() OWNER TO postgres;

DROP TRIGGER IF EXISTS business_settings_set_updated_at ON public.business_settings;
CREATE TRIGGER business_settings_set_updated_at
  BEFORE UPDATE ON public.business_settings
  FOR EACH ROW EXECUTE FUNCTION public.business_settings_set_updated_at();

-- ---------------------------------------------------------------------------
-- get_business_settings — returns the singleton.
--   Visible to anyone with Business settings View+ OR Contractor invoices View+
--   (the contractor invoice batch page surfaces buyer-incomplete warnings).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_business_settings()
RETURNS TABLE (
  id uuid,
  legal_business_name text,
  trading_name text,
  street_address text,
  suburb text,
  city_postcode text,
  email text,
  phone text,
  nzbn text,
  gst_number text,
  created_at timestamptz,
  updated_at timestamptz,
  updated_by uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT (
    private.user_has_page_access('business_settings', 'view')
    OR private.user_has_page_access('contractor_invoices', 'view')
  ) THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  RETURN QUERY
    SELECT
      b.id,
      b.legal_business_name,
      b.trading_name,
      b.street_address,
      b.suburb,
      b.city_postcode,
      b.email,
      b.phone,
      b.nzbn,
      b.gst_number,
      b.created_at,
      b.updated_at,
      b.updated_by
    FROM public.business_settings b
    WHERE b.row_marker = 'singleton'
    LIMIT 1;
END;
$$;

ALTER FUNCTION public.get_business_settings() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_business_settings() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_business_settings() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_business_settings() TO service_role;

-- ---------------------------------------------------------------------------
-- update_business_settings — Business settings Full only.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_business_settings(
  p_legal_business_name text,
  p_trading_name text,
  p_street_address text,
  p_suburb text,
  p_city_postcode text,
  p_email text,
  p_phone text,
  p_nzbn text,
  p_gst_number text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_row public.business_settings%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Not authenticated' USING ERRCODE = '42501';
  END IF;

  IF NOT private.user_has_page_access('business_settings', 'full') THEN
    RAISE EXCEPTION 'Forbidden' USING ERRCODE = '42501';
  END IF;

  UPDATE public.business_settings
  SET
    legal_business_name = COALESCE(NULLIF(trim(p_legal_business_name), ''), ''),
    trading_name = NULLIF(trim(COALESCE(p_trading_name, '')), ''),
    street_address = COALESCE(NULLIF(trim(p_street_address), ''), ''),
    suburb = COALESCE(NULLIF(trim(p_suburb), ''), ''),
    city_postcode = COALESCE(NULLIF(trim(p_city_postcode), ''), ''),
    email = NULLIF(trim(COALESCE(p_email, '')), ''),
    phone = NULLIF(trim(COALESCE(p_phone, '')), ''),
    nzbn = NULLIF(trim(COALESCE(p_nzbn, '')), ''),
    gst_number = NULLIF(trim(COALESCE(p_gst_number, '')), ''),
    updated_by = auth.uid()
  WHERE row_marker = 'singleton'
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    -- Fallback: create the singleton if missing for any reason.
    INSERT INTO public.business_settings (
      legal_business_name, trading_name, street_address, suburb, city_postcode,
      email, phone, nzbn, gst_number, updated_by
    ) VALUES (
      COALESCE(NULLIF(trim(p_legal_business_name), ''), ''),
      NULLIF(trim(COALESCE(p_trading_name, '')), ''),
      COALESCE(NULLIF(trim(p_street_address), ''), ''),
      COALESCE(NULLIF(trim(p_suburb), ''), ''),
      COALESCE(NULLIF(trim(p_city_postcode), ''), ''),
      NULLIF(trim(COALESCE(p_email, '')), ''),
      NULLIF(trim(COALESCE(p_phone, '')), ''),
      NULLIF(trim(COALESCE(p_nzbn, '')), ''),
      NULLIF(trim(COALESCE(p_gst_number, '')), ''),
      auth.uid()
    )
    RETURNING * INTO v_row;
  END IF;

  RETURN to_jsonb(v_row);
END;
$$;

ALTER FUNCTION public.update_business_settings(
  text, text, text, text, text, text, text, text, text
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.update_business_settings(
  text, text, text, text, text, text, text, text, text
) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_business_settings(
  text, text, text, text, text, text, text, text, text
) TO authenticated;
GRANT EXECUTE ON FUNCTION public.update_business_settings(
  text, text, text, text, text, text, text, text, text
) TO service_role;
