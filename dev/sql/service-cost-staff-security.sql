-- Stable plan IDs are not protected if an elevated caller with Staff view can
-- bypass the dated RPC through the old generic elevated table policies.
-- Replace every existing policy on these two tables, keeping authenticated
-- SELECT at Staff view and INSERT/UPDATE at Staff full. No DELETE policy is added.
DO $policies$
DECLARE r record;
BEGIN
  FOR r IN SELECT schemaname,tablename,policyname FROM pg_policies
    WHERE schemaname='public' AND tablename IN ('staff_members','staff_role_assignments')
  LOOP EXECUTE format('DROP POLICY %I ON %I.%I',r.policyname,r.schemaname,r.tablename); END LOOP;
END;
$policies$;
CREATE POLICY staff_members_page_select ON public.staff_members FOR SELECT TO authenticated
  USING ((SELECT private.user_has_page_access('staff','view')));
CREATE POLICY staff_members_page_insert ON public.staff_members FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.user_has_page_access('staff','full')));
CREATE POLICY staff_members_page_update ON public.staff_members FOR UPDATE TO authenticated
  USING ((SELECT private.user_has_page_access('staff','full')))
  WITH CHECK ((SELECT private.user_has_page_access('staff','full')));
CREATE POLICY staff_role_assignments_page_select ON public.staff_role_assignments FOR SELECT TO authenticated
  USING ((SELECT private.user_has_page_access('staff','view')));
CREATE POLICY staff_role_assignments_page_insert ON public.staff_role_assignments FOR INSERT TO authenticated
  WITH CHECK ((SELECT private.user_has_page_access('staff','full')));
CREATE POLICY staff_role_assignments_page_update ON public.staff_role_assignments FOR UPDATE TO authenticated
  USING ((SELECT private.user_has_page_access('staff','full')))
  WITH CHECK ((SELECT private.user_has_page_access('staff','full')));

-- Keep the established delete workflow and non-disclosing errors, while closing
-- the other Staff mutation RPC's old elevated-role-only authorization path.
DO $delete_permission$
BEGIN
  EXECUTE replace(pg_get_functiondef('public.delete_staff_member_admin(uuid)'::regprocedure),
    'private.user_has_elevated_access()', 'private.user_has_page_access(''staff'',''full'')');
END;
$delete_permission$;
