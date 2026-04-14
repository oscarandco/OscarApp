-- Elevated admins: read/write product_master (import line classification keys).

GRANT SELECT, INSERT, UPDATE ON public.product_master TO authenticated;

CREATE POLICY "product_master_elevated_select"
  ON public.product_master FOR SELECT TO authenticated
  USING ((SELECT private.user_has_elevated_access()));

CREATE POLICY "product_master_elevated_insert"
  ON public.product_master FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.user_has_elevated_access()));

CREATE POLICY "product_master_elevated_update"
  ON public.product_master FOR UPDATE TO authenticated
  USING ((SELECT private.user_has_elevated_access()))
  WITH CHECK ((SELECT private.user_has_elevated_access()));
