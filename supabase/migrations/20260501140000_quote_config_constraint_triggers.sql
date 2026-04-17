-- Quote Configuration cross-row / cross-table validation that single-row
-- CHECK constraints cannot express.
--
-- Adds:
--  1. A single-row CHECK on public.quote_services requiring visible_roles to
--     be non-empty when the service is role-based (role_radio input or
--     role_price pricing).
--  2. Three private validation helper functions.
--  3. Three CONSTRAINT TRIGGERs (DEFERRABLE INITIALLY DEFERRED) wiring the
--     helpers onto quote_services, quote_service_role_prices, and
--     quote_service_options so service + children can be written in a single
--     transaction and validated at commit time.
--
-- Invariants enforced (summary):
--  A. pricing_type = 'role_price'   => set of roles in quote_service_role_prices
--                                      equals quote_services.visible_roles.
--  B. (always)                      => no quote_service_role_prices row exists
--                                      for a role not present in visible_roles.
--  C. (per option row)              => quote_service_options.price IS NOT NULL
--                                      iff parent service.pricing_type = 'option_price'.
--  D. input_type IN ('option_radio','dropdown')
--     OR pricing_type = 'option_price'
--                                   => service has >= 1 active option row.


-- 1. Role-based services must have at least one visible role. Safe to add as
-- a CHECK constraint because no service rows exist yet (core tables migration
-- only seeded quote_settings).
ALTER TABLE public.quote_services
  DROP CONSTRAINT IF EXISTS quote_services_role_based_visible_roles_required;

ALTER TABLE public.quote_services
  ADD CONSTRAINT quote_services_role_based_visible_roles_required
  CHECK (
    NOT (input_type = 'role_radio' OR pricing_type = 'role_price')
    OR cardinality(visible_roles) >= 1
  );


-- 2a. Role-price ↔ visible-roles invariant.
--   * pricing_type = 'role_price':
--       - set of roles in quote_service_role_prices equals visible_roles
--         (i.e. every visible role has exactly one row, and no rows exist for
--         roles outside visible_roles).
--   * pricing_type <> 'role_price':
--       - zero rows may exist in quote_service_role_prices for this service.
CREATE OR REPLACE FUNCTION private.validate_quote_service_role_prices(p_service_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_pricing_type text;
  v_visible_roles text[];
  v_extra_roles text[];
  v_missing_roles text[];
  v_row_count integer;
BEGIN
  SELECT pricing_type, visible_roles
    INTO v_pricing_type, v_visible_roles
    FROM public.quote_services
    WHERE id = p_service_id;

  -- Service no longer exists (e.g. cascade delete). Nothing to validate.
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_pricing_type = 'role_price' THEN
    -- No role_price rows for roles outside visible_roles.
    SELECT array_agg(rp.role ORDER BY rp.role)
      INTO v_extra_roles
      FROM public.quote_service_role_prices rp
      WHERE rp.service_id = p_service_id
        AND NOT (rp.role = ANY (v_visible_roles));

    IF v_extra_roles IS NOT NULL THEN
      RAISE EXCEPTION
        'quote_service_role_prices has rows for roles not in visible_roles (service=%, extra_roles=%)',
        p_service_id, v_extra_roles
        USING ERRCODE = '23514';
    END IF;

    -- Every visible role must have a row.
    SELECT array_agg(r ORDER BY r)
      INTO v_missing_roles
      FROM unnest(v_visible_roles) AS r
      WHERE NOT EXISTS (
        SELECT 1 FROM public.quote_service_role_prices rp
        WHERE rp.service_id = p_service_id
          AND rp.role = r
      );

    IF v_missing_roles IS NOT NULL THEN
      RAISE EXCEPTION
        'quote_service_role_prices missing rows for visible roles (service=%, missing_roles=%)',
        p_service_id, v_missing_roles
        USING ERRCODE = '23514';
    END IF;
  ELSE
    -- Non role_price services must have zero role-price rows.
    SELECT count(*) INTO v_row_count
      FROM public.quote_service_role_prices
      WHERE service_id = p_service_id;

    IF v_row_count > 0 THEN
      RAISE EXCEPTION
        'quote_service_role_prices has rows for a non-role_price service (service=%, pricing_type=%, row_count=%)',
        p_service_id, v_pricing_type, v_row_count
        USING ERRCODE = '23514';
    END IF;
  END IF;
END;
$$;

ALTER FUNCTION private.validate_quote_service_role_prices(uuid) OWNER TO postgres;


-- 2b. Option-row price ↔ parent pricing_type invariant (Rule C).
CREATE OR REPLACE FUNCTION private.validate_quote_service_option_pricing(p_service_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_pricing_type text;
  v_bad_count integer;
BEGIN
  SELECT pricing_type
    INTO v_pricing_type
    FROM public.quote_services
    WHERE id = p_service_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_pricing_type = 'option_price' THEN
    SELECT count(*) INTO v_bad_count
      FROM public.quote_service_options
      WHERE service_id = p_service_id AND price IS NULL;

    IF v_bad_count > 0 THEN
      RAISE EXCEPTION
        'quote_service_options.price must be set when parent service.pricing_type = option_price (service=%, null_price_rows=%)',
        p_service_id, v_bad_count
        USING ERRCODE = '23514';
    END IF;
  ELSE
    SELECT count(*) INTO v_bad_count
      FROM public.quote_service_options
      WHERE service_id = p_service_id AND price IS NOT NULL;

    IF v_bad_count > 0 THEN
      RAISE EXCEPTION
        'quote_service_options.price must be null when parent service.pricing_type <> option_price (service=%, pricing_type=%, non_null_price_rows=%)',
        p_service_id, v_pricing_type, v_bad_count
        USING ERRCODE = '23514';
    END IF;
  END IF;
END;
$$;

ALTER FUNCTION private.validate_quote_service_option_pricing(uuid) OWNER TO postgres;


-- 2c. Option-based services must have >= 1 active option (Rule D).
CREATE OR REPLACE FUNCTION private.validate_quote_service_has_active_option(p_service_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_input_type text;
  v_pricing_type text;
  v_active_count integer;
BEGIN
  SELECT input_type, pricing_type
    INTO v_input_type, v_pricing_type
    FROM public.quote_services
    WHERE id = p_service_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_input_type IN ('option_radio', 'dropdown')
     OR v_pricing_type = 'option_price' THEN

    SELECT count(*) INTO v_active_count
      FROM public.quote_service_options
      WHERE service_id = p_service_id AND active = true;

    IF v_active_count < 1 THEN
      RAISE EXCEPTION
        'option-based service requires at least one active option (service=%, input_type=%, pricing_type=%)',
        p_service_id, v_input_type, v_pricing_type
        USING ERRCODE = '23514';
    END IF;
  END IF;
END;
$$;

ALTER FUNCTION private.validate_quote_service_has_active_option(uuid) OWNER TO postgres;


-- 3. Trigger functions. Each invokes the validators relevant to the table it
-- is attached to. All validations are DEFERRED so the whole transaction can
-- stage its writes before the checks run.

-- Fires on quote_services after any (insert/update) change that could affect
-- any of the three invariants.
CREATE OR REPLACE FUNCTION private.quote_services_validate_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  PERFORM private.validate_quote_service_role_prices(NEW.id);
  PERFORM private.validate_quote_service_option_pricing(NEW.id);
  PERFORM private.validate_quote_service_has_active_option(NEW.id);
  RETURN NULL;
END;
$$;

ALTER FUNCTION private.quote_services_validate_row() OWNER TO postgres;


-- Fires on quote_service_role_prices after insert/update/delete.
CREATE OR REPLACE FUNCTION private.quote_service_role_prices_validate_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_service_id uuid;
BEGIN
  v_service_id := COALESCE(NEW.service_id, OLD.service_id);
  PERFORM private.validate_quote_service_role_prices(v_service_id);
  RETURN NULL;
END;
$$;

ALTER FUNCTION private.quote_service_role_prices_validate_row() OWNER TO postgres;


-- Fires on quote_service_options after insert/update/delete.
-- Checks both the option-pricing invariant (Rule C) and the active-option
-- invariant (Rule D) for the affected service.
CREATE OR REPLACE FUNCTION private.quote_service_options_validate_row()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  v_service_id uuid;
BEGIN
  v_service_id := COALESCE(NEW.service_id, OLD.service_id);
  PERFORM private.validate_quote_service_option_pricing(v_service_id);
  PERFORM private.validate_quote_service_has_active_option(v_service_id);
  RETURN NULL;
END;
$$;

ALTER FUNCTION private.quote_service_options_validate_row() OWNER TO postgres;


-- 4. Constraint triggers. DEFERRABLE INITIALLY DEFERRED so service + options
-- + role prices can be inserted/updated in the same transaction without
-- false failures mid-statement.

DROP TRIGGER IF EXISTS trg_quote_services_validate
  ON public.quote_services;

CREATE CONSTRAINT TRIGGER trg_quote_services_validate
  AFTER INSERT OR UPDATE OF input_type, pricing_type, visible_roles
  ON public.quote_services
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION private.quote_services_validate_row();


DROP TRIGGER IF EXISTS trg_quote_service_role_prices_validate
  ON public.quote_service_role_prices;

CREATE CONSTRAINT TRIGGER trg_quote_service_role_prices_validate
  AFTER INSERT OR UPDATE OR DELETE
  ON public.quote_service_role_prices
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION private.quote_service_role_prices_validate_row();


DROP TRIGGER IF EXISTS trg_quote_service_options_validate
  ON public.quote_service_options;

CREATE CONSTRAINT TRIGGER trg_quote_service_options_validate
  AFTER INSERT OR UPDATE OR DELETE
  ON public.quote_service_options
  DEFERRABLE INITIALLY DEFERRED
  FOR EACH ROW
  EXECUTE FUNCTION private.quote_service_options_validate_row();
