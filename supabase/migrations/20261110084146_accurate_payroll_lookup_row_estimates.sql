-- These lookups return at most one row. Default ROWS 1000 multiplies across
-- repeated lateral joins and gives payroll reports astronomical cardinality estimates.
-- Planner metadata only: function bodies, permissions and financial rules are unchanged.
ALTER FUNCTION public.staff_profile_at(uuid,date) ROWS 1;
ALTER FUNCTION private.service_commission_basis(uuid,date,numeric,numeric,boolean,boolean,boolean,boolean) ROWS 1;
