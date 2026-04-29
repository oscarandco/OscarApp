-- Allow admin mappings to persist staff_member_id; enforce stylist/assistant
-- require staff at the RPC layer (unchanged permissions on who may call).

CREATE OR REPLACE FUNCTION public.create_access_mapping(
  p_user_id uuid,
  p_staff_member_id uuid,
  p_access_role text,
  p_is_active boolean DEFAULT true
) RETURNS public.staff_member_user_access
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_row public.staff_member_user_access;
  v_role text;
BEGIN
  IF NOT private.user_can_manage_access_mappings() THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  v_role := lower(trim(p_access_role));

  IF v_role IN ('stylist', 'assistant') AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'Stylist and Assistant mappings require staff_member_id';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.staff_member_user_access m
    WHERE m.user_id = p_user_id
  ) THEN
    RAISE EXCEPTION 'A mapping already exists for this user';
  END IF;

  INSERT INTO public.staff_member_user_access (
    user_id,
    staff_member_id,
    access_role,
    is_active
  )
  VALUES (
    p_user_id,
    p_staff_member_id,
    v_role,
    p_is_active
  )
  RETURNING * INTO v_row;

  RETURN v_row;
END;
$$;

ALTER FUNCTION public.create_access_mapping(uuid, uuid, text, boolean) OWNER TO postgres;


CREATE OR REPLACE FUNCTION public.update_access_mapping(
  p_mapping_id uuid,
  p_staff_member_id uuid,
  p_access_role text,
  p_is_active boolean
) RETURNS public.staff_member_user_access
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_row public.staff_member_user_access;
  v_role text;
BEGIN
  IF NOT private.user_can_manage_access_mappings() THEN
    RAISE EXCEPTION 'Access denied';
  END IF;

  v_role := lower(trim(p_access_role));

  IF v_role IN ('stylist', 'assistant') AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'Stylist and Assistant mappings require staff_member_id';
  END IF;

  UPDATE public.staff_member_user_access
  SET
    staff_member_id = p_staff_member_id,
    access_role = v_role,
    is_active = p_is_active,
    updated_at = now()
  WHERE id = p_mapping_id
  RETURNING * INTO v_row;

  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Mapping not found';
  END IF;

  RETURN v_row;
END;
$$;

ALTER FUNCTION public.update_access_mapping(uuid, uuid, text, boolean) OWNER TO postgres;
