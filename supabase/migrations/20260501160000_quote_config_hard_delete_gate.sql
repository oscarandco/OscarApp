-- Hard-delete gate for Quote Configuration.
-- Adds BEFORE DELETE triggers on quote_sections, quote_services, and
-- quote_service_options that raise a named exception when the target row is
-- referenced by saved quote tables. This surfaces a clean, admin-friendly
-- error the UI can match on, instead of the generic FK RESTRICT violation.
--
-- Message format: each exception starts with a stable snake_case identifier
-- so callers can pattern-match reliably:
--   quote_section_used_in_saved_quotes
--   quote_service_used_in_saved_quotes
--   quote_service_option_used_in_saved_quotes
-- ERRCODE is 23503 (foreign_key_violation) to stay in the same class as the
-- underlying RESTRICT constraint.

-- 1. Section delete gate.
CREATE OR REPLACE FUNCTION private.quote_sections_block_delete_if_used()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.saved_quote_lines
    WHERE section_id = OLD.id
  ) THEN
    RAISE EXCEPTION
      'quote_section_used_in_saved_quotes: section % is referenced by saved_quote_lines and cannot be deleted.',
      OLD.id
      USING ERRCODE = '23503',
            HINT = 'Archive the section (set active = false) instead.';
  END IF;
  RETURN OLD;
END;
$$;

ALTER FUNCTION private.quote_sections_block_delete_if_used() OWNER TO postgres;


-- 2. Service delete gate.
CREATE OR REPLACE FUNCTION private.quote_services_block_delete_if_used()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.saved_quote_lines
    WHERE service_id = OLD.id
  ) THEN
    RAISE EXCEPTION
      'quote_service_used_in_saved_quotes: service % is referenced by saved_quote_lines and cannot be deleted.',
      OLD.id
      USING ERRCODE = '23503',
            HINT = 'Archive the service (set active = false) instead.';
  END IF;
  RETURN OLD;
END;
$$;

ALTER FUNCTION private.quote_services_block_delete_if_used() OWNER TO postgres;


-- 3. Service option delete gate.
CREATE OR REPLACE FUNCTION private.quote_service_options_block_delete_if_used()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.saved_quote_line_options
    WHERE service_option_id = OLD.id
  ) THEN
    RAISE EXCEPTION
      'quote_service_option_used_in_saved_quotes: option % is referenced by saved_quote_line_options and cannot be deleted.',
      OLD.id
      USING ERRCODE = '23503',
            HINT = 'Archive the option (set active = false) instead.';
  END IF;
  RETURN OLD;
END;
$$;

ALTER FUNCTION private.quote_service_options_block_delete_if_used() OWNER TO postgres;


-- Wire the triggers. BEFORE DELETE so they fire before the FK RESTRICT check,
-- giving the user the named error rather than the generic FK violation.
DROP TRIGGER IF EXISTS trg_quote_sections_block_delete_if_used
  ON public.quote_sections;

CREATE TRIGGER trg_quote_sections_block_delete_if_used
  BEFORE DELETE ON public.quote_sections
  FOR EACH ROW
  EXECUTE FUNCTION private.quote_sections_block_delete_if_used();


DROP TRIGGER IF EXISTS trg_quote_services_block_delete_if_used
  ON public.quote_services;

CREATE TRIGGER trg_quote_services_block_delete_if_used
  BEFORE DELETE ON public.quote_services
  FOR EACH ROW
  EXECUTE FUNCTION private.quote_services_block_delete_if_used();


DROP TRIGGER IF EXISTS trg_quote_service_options_block_delete_if_used
  ON public.quote_service_options;

CREATE TRIGGER trg_quote_service_options_block_delete_if_used
  BEFORE DELETE ON public.quote_service_options
  FOR EACH ROW
  EXECUTE FUNCTION private.quote_service_options_block_delete_if_used();
