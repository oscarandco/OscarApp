-- Tiny helper RPC: return the logged-in user's FTE from staff_members.
-- Used by the KPI dashboard to normalise self/staff KPI values for
-- sub-1.0-FTE stylists on display. Read-only; no KPI math or RLS
-- behaviour changes anywhere else.
--
-- Scope: auth.uid() only. staff_members is RLS-locked to elevated
-- callers, so a stylist/assistant cannot query the table directly —
-- this SECURITY DEFINER wrapper exposes *just* their own fte (scalar)
-- and nothing else.

CREATE OR REPLACE FUNCTION public.get_my_fte()
RETURNS numeric
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT sm.fte
  FROM public.staff_member_user_access a
  JOIN public.staff_members sm ON sm.id = a.staff_member_id
  WHERE a.user_id = auth.uid()
    AND a.is_active = true
  ORDER BY sm.full_name NULLS LAST
  LIMIT 1
$$;

COMMENT ON FUNCTION public.get_my_fte() IS
  'Returns the logged-in user''s staff FTE (numeric(5,4)) or NULL if no active staff mapping / no fte set. Consumed by the KPI dashboard to normalise self/staff KPI cards for sub-1.0-FTE stylists.';

GRANT EXECUTE ON FUNCTION public.get_my_fte() TO authenticated;
