-- Staff Admin write path for effective-dated role/pay history.
--
-- Adds two RPCs:
--   1. public.apply_staff_role_assignment(...)
--      Closes the existing open assignment and inserts a new one (or
--      updates an assignment in place when one already starts on the
--      requested effective_start_date), then mirrors the latest values
--      onto the staff_members "current snapshot" row.
--
--   2. public.list_staff_role_assignments(p_staff_member_id)
--      Returns the assignment history for a staff member joined with
--      the location name for display. Read-only.
--
-- Both RPCs gate on private.user_has_elevated_access() to match the
-- existing Staff Admin permission pattern (see 20260430290000_staff
-- _configuration_access.sql).
--
-- This migration does NOT change commission formulas, payroll views,
-- KPI calculations, contractor invoice logic, voucher exclusion, or
-- saved invoices.

-- ---------------------------------------------------------------------------
-- 1. public.apply_staff_role_assignment
--    Returns a jsonb envelope with:
--      success                 boolean
--      action                  'updated_existing' | 'inserted_new'
--      assignment_id           uuid    (target row)
--      previous_open_id        uuid    (closed open row, NULL if none/N/A)
--      previous_open_end_date  date    (new effective_end_date of the closed
--                                       open row, NULL if none/N/A)
--      staff_member_id         uuid
--      effective_start_date    date
--      synced_staff_members    boolean (true when the new row is the latest)
--      message                 text
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.apply_staff_role_assignment(
  p_staff_member_id       uuid,
  p_effective_start_date  date,
  p_primary_role          text,
  p_secondary_roles       text,
  p_employment_type       text,
  p_remuneration_plan     text,
  p_fte                   numeric,
  p_primary_location_id   uuid,
  p_reason                text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $fn$
DECLARE
  v_caller            uuid := auth.uid();
  v_existing_id       uuid;
  v_assignment_id     uuid;
  v_open_id           uuid;
  v_open_start        date;
  v_new_open_end_date date;
  v_action            text;
  v_synced            boolean := false;
  -- Cleaned inputs.
  v_primary_role        text := NULLIF(btrim(p_primary_role),      '');
  v_secondary_roles     text := NULLIF(btrim(p_secondary_roles),   '');
  v_employment_type     text := NULLIF(btrim(p_employment_type),   '');
  v_remuneration_plan   text := NULLIF(btrim(p_remuneration_plan), '');
  v_reason              text := NULLIF(btrim(p_reason),            '');
BEGIN
  -- 1. Authorization.
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
  IF p_effective_start_date IS NULL THEN
    RAISE EXCEPTION 'p_effective_start_date is required' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.staff_members sm WHERE sm.id = p_staff_member_id
  ) THEN
    RAISE EXCEPTION 'staff member not found: %', p_staff_member_id
      USING ERRCODE = 'P0002';
  END IF;

  -- 3. Defer the no-overlap exclusion so the "close old + insert new"
  --    pair is checked atomically at commit. The constraint was defined
  --    DEFERRABLE INITIALLY IMMEDIATE in 20260828120000.
  SET CONSTRAINTS public.staff_role_assignments_no_overlap DEFERRED;

  -- 4. Update in place if an assignment already starts on this date.
  SELECT a.id INTO v_existing_id
  FROM public.staff_role_assignments a
  WHERE a.staff_member_id      = p_staff_member_id
    AND a.effective_start_date = p_effective_start_date
  LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    UPDATE public.staff_role_assignments
       SET primary_role        = v_primary_role,
           secondary_roles     = v_secondary_roles,
           employment_type     = v_employment_type,
           remuneration_plan   = v_remuneration_plan,
           fte                 = p_fte,
           primary_location_id = p_primary_location_id,
           reason              = COALESCE(v_reason, reason),
           updated_at          = now(),
           updated_by          = v_caller
     WHERE id = v_existing_id;

    v_assignment_id := v_existing_id;
    v_action        := 'updated_existing';

  ELSE
    -- 5. Close the currently-open assignment, if any.
    SELECT a.id, a.effective_start_date
      INTO v_open_id, v_open_start
    FROM public.staff_role_assignments a
    WHERE a.staff_member_id    = p_staff_member_id
      AND a.effective_end_date IS NULL
    LIMIT 1;

    IF v_open_id IS NOT NULL THEN
      IF v_open_start >= p_effective_start_date THEN
        RAISE EXCEPTION
          'p_effective_start_date (%) must be after the current open assignment start (%)',
          p_effective_start_date, v_open_start
          USING ERRCODE = '22023';
      END IF;

      v_new_open_end_date := (p_effective_start_date - INTERVAL '1 day')::date;

      UPDATE public.staff_role_assignments
         SET effective_end_date = v_new_open_end_date,
             updated_at         = now(),
             updated_by         = v_caller
       WHERE id = v_open_id;
    END IF;

    -- 6. Insert the new open-ended assignment.
    INSERT INTO public.staff_role_assignments (
      staff_member_id,
      effective_start_date,
      effective_end_date,
      primary_role,
      secondary_roles,
      employment_type,
      remuneration_plan,
      fte,
      primary_location_id,
      reason,
      created_by,
      updated_by
    ) VALUES (
      p_staff_member_id,
      p_effective_start_date,
      NULL,
      v_primary_role,
      v_secondary_roles,
      v_employment_type,
      v_remuneration_plan,
      p_fte,
      p_primary_location_id,
      COALESCE(v_reason, 'Role/pay change'),
      v_caller,
      v_caller
    )
    RETURNING id INTO v_assignment_id;

    v_action := 'inserted_new';
  END IF;

  -- 7. Sync staff_members ONLY if the saved assignment is now the
  --    latest (open-ended). This is the rule from the spec: the
  --    staff_members row represents the current/latest profile, so
  --    a back-dated correction that closes (i.e. an end date is set
  --    by some other admin afterwards) should not overwrite the
  --    current snapshot.
  IF EXISTS (
    SELECT 1
    FROM public.staff_role_assignments a
    WHERE a.id                 = v_assignment_id
      AND a.effective_end_date IS NULL
  ) THEN
    UPDATE public.staff_members sm
       SET primary_role        = v_primary_role,
           secondary_roles     = v_secondary_roles,
           employment_type     = v_employment_type,
           remuneration_plan   = v_remuneration_plan,
           fte                 = p_fte,
           primary_location_id = p_primary_location_id,
           updated_at          = now()
     WHERE sm.id = p_staff_member_id;
    v_synced := true;
  END IF;

  RETURN jsonb_build_object(
    'success',                 true,
    'action',                  v_action,
    'assignment_id',           v_assignment_id,
    'previous_open_id',        v_open_id,
    'previous_open_end_date',  v_new_open_end_date,
    'staff_member_id',         p_staff_member_id,
    'effective_start_date',    p_effective_start_date,
    'synced_staff_members',    v_synced,
    'message',
      CASE
        WHEN v_action = 'updated_existing'
          THEN 'Updated existing assignment effective ' || p_effective_start_date::text
        ELSE 'Inserted new assignment effective ' || p_effective_start_date::text
      END
  );
END;
$fn$;

ALTER FUNCTION public.apply_staff_role_assignment(
  uuid, date, text, text, text, text, numeric, uuid, text
) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.apply_staff_role_assignment(
  uuid, date, text, text, text, text, numeric, uuid, text
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.apply_staff_role_assignment(
  uuid, date, text, text, text, text, numeric, uuid, text
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.apply_staff_role_assignment(
  uuid, date, text, text, text, text, numeric, uuid, text
) TO service_role;

COMMENT ON FUNCTION public.apply_staff_role_assignment(
  uuid, date, text, text, text, text, numeric, uuid, text
) IS
  'Applies a new effective-dated staff role/pay assignment. Closes the currently-open assignment (effective_end_date = p_effective_start_date - 1 day) and inserts a new open assignment, OR updates in place when an assignment already starts on p_effective_start_date. Syncs the latest open assignment back onto staff_members (current snapshot). Elevated access required.';


-- ---------------------------------------------------------------------------
-- 2. public.list_staff_role_assignments
--    Returns history rows joined with the primary location name. Used
--    by Staff Admin's "Role and pay history" panel.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.list_staff_role_assignments(
  p_staff_member_id uuid
)
RETURNS TABLE (
  id                     uuid,
  staff_member_id        uuid,
  effective_start_date   date,
  effective_end_date     date,
  primary_role           text,
  secondary_roles        text,
  employment_type        text,
  remuneration_plan      text,
  fte                    numeric(5, 4),
  primary_location_id    uuid,
  primary_location_name  text,
  reason                 text,
  created_at             timestamptz,
  created_by             uuid,
  updated_at             timestamptz,
  updated_by             uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, private, pg_temp
AS $fn$
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;
  IF NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized' USING ERRCODE = '42501';
  END IF;

  IF p_staff_member_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  SELECT
    a.id,
    a.staff_member_id,
    a.effective_start_date,
    a.effective_end_date,
    a.primary_role,
    a.secondary_roles,
    a.employment_type,
    a.remuneration_plan,
    a.fte,
    a.primary_location_id,
    l.name AS primary_location_name,
    a.reason,
    a.created_at,
    a.created_by,
    a.updated_at,
    a.updated_by
  FROM public.staff_role_assignments a
  LEFT JOIN public.locations l ON l.id = a.primary_location_id
  WHERE a.staff_member_id = p_staff_member_id
  ORDER BY a.effective_start_date DESC, a.created_at DESC;
END;
$fn$;

ALTER FUNCTION public.list_staff_role_assignments(uuid) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.list_staff_role_assignments(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.list_staff_role_assignments(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.list_staff_role_assignments(uuid) TO service_role;

COMMENT ON FUNCTION public.list_staff_role_assignments(uuid) IS
  'Returns the staff_role_assignments history for a staff member joined with the primary location name, ordered most-recent-first. Elevated access required.';
