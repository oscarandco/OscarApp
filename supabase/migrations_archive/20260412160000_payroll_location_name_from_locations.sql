-- Payroll RPC contract: expose location_id (existing) + location_name from public.locations.
--
-- Assumptions (adjust in your project if different):
-- - public.locations has id uuid (PK) and a text column **name** for display.
-- - Weekly summary/detail sources expose a column **location_id** joinable to locations.id.
--
-- This migration adds a small helper for optional use in SQL Editor refactors.
-- You must update each of the four payroll RPCs (or their underlying views) so every
-- returned row includes **location_name** — typically:
--
--   LEFT JOIN public.locations AS loc ON loc.id = <row_alias>.location_id
--   ... SELECT ..., <row_alias>.location_id, loc.name::text AS location_name, ...
--
-- RPC names and parameters stay the same; only the SELECT list / view definition gains one column.

CREATE OR REPLACE FUNCTION private.payroll_location_name(p_location_id uuid)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
  SELECT COALESCE(NULLIF(TRIM(l.name::text), ''), p_location_id::text)
  FROM public.locations AS l
  WHERE l.id = p_location_id
$$;

REVOKE ALL ON FUNCTION private.payroll_location_name(uuid) FROM PUBLIC;

COMMENT ON FUNCTION private.payroll_location_name(uuid) IS
  'Optional scalar lookup for location label; prefer JOIN ... locations AS loc ON loc.id = location_id AND loc.name AS location_name in RPC/view for performance.';

-- Integration checklist (apply in Supabase SQL editor to your existing definitions):
-- 1) get_my_commission_summary_weekly()
-- 2) get_my_commission_lines_weekly(date)
-- 3) get_admin_payroll_summary_weekly()
-- 4) get_admin_payroll_lines_weekly(date)
--
-- Each result row must include columns: location_id uuid (or compatible), location_name text.
-- If your locations table uses only `location_name` instead of `name`, replace `l.name` with `l.location_name` in your JOIN.
