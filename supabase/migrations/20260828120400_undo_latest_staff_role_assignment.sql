-- Safe undo for the latest open-ended staff role/pay assignment.
--
-- Adds public.undo_latest_staff_role_assignment(p_staff_member_id, p_assignment_id, p_reason).
--
-- This is intentionally NARROW:
--   * Only the staff member's currently-open assignment can be deleted.
--   * There must be at least one previous assignment to reopen; if not, the
--     RPC raises and changes nothing.
--   * Older/middle history rows can NEVER be deleted through this RPC.
--
-- Behaviour on success:
--   1. Deletes the open assignment row.
--   2. Reopens the immediately previous assignment (effective_end_date := null).
--   3. Mirrors that previous row's role/pay/FTE/location back onto
--      staff_members so the "current snapshot" matches what payroll /
--      commission / KPI views will now read as effective today.
--
-- This migration does NOT change commission formulas, payroll views,
-- KPI calculations, contractor invoice logic, voucher exclusion, or any
-- saved invoices.

CREATE OR REPLACE FUNCTION public.undo_latest_staff_role_assignment(
  p_staff_member_id uuid,
  p_assignment_id   uuid,
  p_reason          text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $fn$
DECLARE
  v_caller         uuid := auth.uid();
  v_total_rows     integer;
  v_latest_end     date;
  v_prev_id        uuid;
  v_prev_start     date;
  v_reason_clean   text := NULLIF(btrim(p_reason), '');
  -- Snapshot of the row we are about to reopen, used to sync staff_members.
  v_prev_primary_role        text;
  v_prev_secondary_roles     text;
  v_prev_employment_type     text;
  v_prev_remuneration_plan   text;
  v_prev_fte                 numeric(5, 4);
  v_prev_primary_location_id uuid;
BEGIN
  -- 1. Authorization (matches existing Staff Admin pattern).
  IF v_caller IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  IF NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  -- 2. Input validation.
  IF p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'p_staff_member_id is required' USING ERRCODE = '22023';
  END IF;
  IF p_assignment_id IS NULL THEN
    RAISE EXCEPTION 'p_assignment_id is required' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.staff_members sm WHERE sm.id = p_staff_member_id
  ) THEN
    RAISE EXCEPTION 'staff member not found: %', p_staff_member_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 3. The supplied assignment must belong to the supplied staff member
  --    AND be the CURRENT OPEN one (effective_end_date IS NULL).
  SELECT a.effective_end_date
    INTO v_latest_end
  FROM public.staff_role_assignments a
  WHERE a.id              = p_assignment_id
    AND a.staff_member_id = p_staff_member_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'assignment % does not belong to staff member %',
      p_assignment_id, p_staff_member_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_latest_end IS NOT NULL THEN
    RAISE EXCEPTION
      'assignment % is not the currently open assignment (effective_end_date = %); only the latest open row can be undone',
      p_assignment_id, v_latest_end
      USING ERRCODE = '22023';
  END IF;

  -- 4. Require at least 2 history rows for this staff member.
  SELECT count(*)::integer
    INTO v_total_rows
  FROM public.staff_role_assignments
  WHERE staff_member_id = p_staff_member_id;

  IF v_total_rows < 2 THEN
    RAISE EXCEPTION
      'cannot undo: staff member % has only one role/pay history row',
      p_staff_member_id
      USING ERRCODE = '22023';
  END IF;

  -- 5. Locate the immediately-previous assignment. The "previous" is the
  --    row with the largest effective_start_date that is not the one we
  --    are removing. Tie-break by created_at DESC to match the history
  --    panel's ordering. Lock both the row we're deleting and the row
  --    we're reopening for the rest of the transaction.
  SELECT a.id, a.effective_start_date,
         a.primary_role, a.secondary_roles, a.employment_type,
         a.remuneration_plan, a.fte, a.primary_location_id
    INTO v_prev_id, v_prev_start,
         v_prev_primary_role, v_prev_secondary_roles, v_prev_employment_type,
         v_prev_remuneration_plan, v_prev_fte, v_prev_primary_location_id
  FROM public.staff_role_assignments a
  WHERE a.staff_member_id = p_staff_member_id
    AND a.id <> p_assignment_id
  ORDER BY a.effective_start_date DESC, a.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF v_prev_id IS NULL THEN
    -- Defensive: covered by v_total_rows < 2 above, but keeps the
    -- intent explicit if that count check is ever changed.
    RAISE EXCEPTION
      'cannot undo: no previous assignment found for staff member %',
      p_staff_member_id
      USING ERRCODE = '22023';
  END IF;

  -- 6. Defer the no-overlap exclusion so the delete-then-reopen pair is
  --    checked atomically at commit. The constraint was defined
  --    DEFERRABLE INITIALLY IMMEDIATE in 20260828120000.
  SET CONSTRAINTS public.staff_role_assignments_no_overlap DEFERRED;

  -- 7. Delete the current open assignment.
  DELETE FROM public.staff_role_assignments WHERE id = p_assignment_id;

  -- 8. Reopen the previous assignment.
  UPDATE public.staff_role_assignments
     SET effective_end_date = NULL,
         updated_at         = now(),
         updated_by         = v_caller
   WHERE id = v_prev_id;

  -- 9. Sync staff_members (current snapshot) back to the reopened row.
  UPDATE public.staff_members sm
     SET primary_role        = v_prev_primary_role,
         secondary_roles     = v_prev_secondary_roles,
         employment_type     = v_prev_employment_type,
         remuneration_plan   = v_prev_remuneration_plan,
         fte                 = v_prev_fte,
         primary_location_id = v_prev_primary_location_id,
         updated_at          = now()
   WHERE sm.id = p_staff_member_id;

  RETURN jsonb_build_object(
    'success',                 true,
    'deleted_assignment_id',   p_assignment_id,
    'reopened_assignment_id',  v_prev_id,
    'reopened_effective_start_date', v_prev_start,
    'staff_member_id',         p_staff_member_id,
    'reason',                  v_reason_clean,
    'message',
      'Removed latest assignment and reopened previous assignment effective '
      || v_prev_start::text
  );
END;
$fn$;

ALTER FUNCTION public.undo_latest_staff_role_assignment(uuid, uuid, text) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.undo_latest_staff_role_assignment(uuid, uuid, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.undo_latest_staff_role_assignment(uuid, uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.undo_latest_staff_role_assignment(uuid, uuid, text) TO service_role;

COMMENT ON FUNCTION public.undo_latest_staff_role_assignment(uuid, uuid, text) IS
  'Deletes the CURRENT OPEN role/pay assignment for a staff member (must match p_assignment_id and belong to p_staff_member_id), reopens the immediately previous assignment (sets effective_end_date = null), and syncs staff_members back to the reopened row. Rejects if there is only one history row or if the supplied assignment is not the open one. Older/middle history rows can not be deleted via this RPC. Elevated access required.';
