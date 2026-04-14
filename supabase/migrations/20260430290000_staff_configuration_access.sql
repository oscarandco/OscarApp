-- Staff Configuration admin: extend staff master columns, RLS for elevated users, updated_at trigger.

ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS secondary_roles text,
  ADD COLUMN IF NOT EXISTS fte numeric(5, 4),
  ADD COLUMN IF NOT EXISTS employment_start_date date,
  ADD COLUMN IF NOT EXISTS employment_end_date date;

COMMENT ON COLUMN public.staff_members.secondary_roles IS 'Optional; comma-separated or free text matching org conventions.';
COMMENT ON COLUMN public.staff_members.fte IS 'Full-time equivalent (0–1 typical).';
COMMENT ON COLUMN public.staff_members.employment_start_date IS 'Employment start (optional).';
COMMENT ON COLUMN public.staff_members.employment_end_date IS 'Employment end (optional).';

GRANT SELECT, INSERT, UPDATE ON public.staff_members TO authenticated;

DROP POLICY IF EXISTS "staff_members_elevated_select" ON public.staff_members;
DROP POLICY IF EXISTS "staff_members_elevated_insert" ON public.staff_members;
DROP POLICY IF EXISTS "staff_members_elevated_update" ON public.staff_members;

CREATE POLICY "staff_members_elevated_select"
  ON public.staff_members
  FOR SELECT
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()));

CREATE POLICY "staff_members_elevated_insert"
  ON public.staff_members
  FOR INSERT
  TO authenticated
  WITH CHECK ((SELECT private.user_has_elevated_access()));

CREATE POLICY "staff_members_elevated_update"
  ON public.staff_members
  FOR UPDATE
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()))
  WITH CHECK ((SELECT private.user_has_elevated_access()));

DROP TRIGGER IF EXISTS trg_staff_members_updated_at ON public.staff_members;
CREATE TRIGGER trg_staff_members_updated_at
  BEFORE UPDATE ON public.staff_members
  FOR EACH ROW
  EXECUTE FUNCTION public.set_updated_at();
