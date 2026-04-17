-- Enable RLS and elevated-access (manager/admin/superadmin) policies on the
-- Quote Configuration core tables. No stylist read policies yet; those land
-- with the stylist-facing quote page migration.

GRANT SELECT, INSERT, UPDATE, DELETE ON public.quote_settings            TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.quote_sections            TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.quote_services            TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.quote_service_options     TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.quote_service_role_prices TO authenticated;

ALTER TABLE public.quote_settings            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quote_sections            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quote_services            ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quote_service_options     ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.quote_service_role_prices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "quote_settings_elevated_all"            ON public.quote_settings;
DROP POLICY IF EXISTS "quote_sections_elevated_all"            ON public.quote_sections;
DROP POLICY IF EXISTS "quote_services_elevated_all"            ON public.quote_services;
DROP POLICY IF EXISTS "quote_service_options_elevated_all"     ON public.quote_service_options;
DROP POLICY IF EXISTS "quote_service_role_prices_elevated_all" ON public.quote_service_role_prices;

CREATE POLICY "quote_settings_elevated_all"
  ON public.quote_settings
  FOR ALL
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()))
  WITH CHECK ((SELECT private.user_has_elevated_access()));

CREATE POLICY "quote_sections_elevated_all"
  ON public.quote_sections
  FOR ALL
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()))
  WITH CHECK ((SELECT private.user_has_elevated_access()));

CREATE POLICY "quote_services_elevated_all"
  ON public.quote_services
  FOR ALL
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()))
  WITH CHECK ((SELECT private.user_has_elevated_access()));

CREATE POLICY "quote_service_options_elevated_all"
  ON public.quote_service_options
  FOR ALL
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()))
  WITH CHECK ((SELECT private.user_has_elevated_access()));

CREATE POLICY "quote_service_role_prices_elevated_all"
  ON public.quote_service_role_prices
  FOR ALL
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()))
  WITH CHECK ((SELECT private.user_has_elevated_access()));
