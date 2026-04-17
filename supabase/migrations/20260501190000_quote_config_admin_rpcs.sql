-- Admin-facing transactional RPCs for Quote Configuration:
--   public.save_quote_service(payload jsonb)     RETURNS uuid
--   public.delete_quote_section(p_section_id)    RETURNS void
--
-- Needed because PostgREST wraps each HTTP request in its own transaction and
-- the deferred constraint triggers on quote_services / quote_service_options /
-- quote_service_role_prices (see 20260501140000_quote_config_constraint_triggers.sql)
-- require service + options + role prices to be written together so invariants
-- line up at commit time.
--
-- Authorization is via private.user_has_elevated_access(); RLS on the tables
-- still applies but these functions are SECURITY DEFINER so the function body
-- runs with elevated privileges once the gate passes.

-- ---------------------------------------------------------------------------
-- save_quote_service(payload jsonb)
--
-- Upsert shape:
-- {
--   "id":                        uuid | null,      -- null => create
--   "section_id":                uuid (required on create),
--   "name":                      text (required),
--   "internal_key":              text | null,
--   "active":                    boolean,
--   "display_order":             integer | null,   -- null => max+1 within section
--   "help_text":                 text | null,
--   "summary_label_override":    text | null,
--   "input_type":                text (required, allowed set),
--   "pricing_type":              text (required, allowed set),
--   "visible_roles":             text[] (defaults to []),
--   "fixed_price":               numeric | null,
--   "numeric_config":            jsonb | null,
--   "extra_unit_config":         jsonb | null,
--   "special_extra_config":      jsonb | null,
--   "link_to_base_service_id":   uuid | null,
--   "include_in_quote_summary":  boolean,
--   "summary_group_override":    text | null,
--   "admin_notes":               text | null,
--   "role_prices": [
--     { "role": text, "price": numeric }, ...       -- only relevant for role_price
--   ],
--   "options": [
--     { "id": uuid | null, "label": text, "value_key": text,
--       "display_order": integer, "active": boolean,
--       "price": numeric | null }, ...
--   ]
-- }
--
-- Returns the service id (created or updated).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_quote_service(payload jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_id                       uuid;
  v_section_id               uuid;
  v_existing                 public.quote_services%ROWTYPE;
  v_display_order            integer;
  v_name                     text;
  v_internal_key             text;
  v_active                   boolean;
  v_help_text                text;
  v_summary_label_override   text;
  v_input_type               text;
  v_pricing_type             text;
  v_visible_roles            text[];
  v_fixed_price              numeric(10, 2);
  v_numeric_config           jsonb;
  v_extra_unit_config        jsonb;
  v_special_extra_config     jsonb;
  v_link_to_base_service_id  uuid;
  v_include_in_summary       boolean;
  v_summary_group_override   text;
  v_admin_notes              text;
  v_role_prices              jsonb;
  v_options                  jsonb;
  v_incoming_option_ids      uuid[];
  v_option                   jsonb;
  v_option_id                uuid;
BEGIN
  IF NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'save_quote_service: not authorized'
      USING ERRCODE = '42501';
  END IF;

  -- Defer all constraint checks until commit so reconciliation of options and
  -- role prices can happen in any order without tripping DEFERRABLE INITIALLY
  -- IMMEDIATE unique constraints or the cross-table CONSTRAINT TRIGGERs.
  SET CONSTRAINTS ALL DEFERRED;

  IF payload IS NULL OR jsonb_typeof(payload) <> 'object' THEN
    RAISE EXCEPTION 'save_quote_service: payload must be a json object';
  END IF;

  v_id          := NULLIF(payload ->> 'id', '')::uuid;
  v_section_id  := NULLIF(payload ->> 'section_id', '')::uuid;
  v_name        := btrim(coalesce(payload ->> 'name', ''));
  IF v_name = '' THEN
    RAISE EXCEPTION 'save_quote_service: name is required';
  END IF;

  v_internal_key := NULLIF(btrim(coalesce(payload ->> 'internal_key', '')), '');
  v_active := COALESCE((payload ->> 'active')::boolean, true);
  v_help_text := NULLIF(btrim(coalesce(payload ->> 'help_text', '')), '');
  v_summary_label_override :=
    NULLIF(btrim(coalesce(payload ->> 'summary_label_override', '')), '');
  v_input_type := coalesce(payload ->> 'input_type', 'checkbox');
  v_pricing_type := coalesce(payload ->> 'pricing_type', 'fixed_price');
  v_fixed_price := NULLIF(payload ->> 'fixed_price', '')::numeric(10, 2);

  IF (payload ? 'numeric_config')
     AND jsonb_typeof(payload -> 'numeric_config') = 'object' THEN
    v_numeric_config := payload -> 'numeric_config';
  ELSE
    v_numeric_config := NULL;
  END IF;

  IF (payload ? 'extra_unit_config')
     AND jsonb_typeof(payload -> 'extra_unit_config') = 'object' THEN
    v_extra_unit_config := payload -> 'extra_unit_config';
  ELSE
    v_extra_unit_config := NULL;
  END IF;

  IF (payload ? 'special_extra_config')
     AND jsonb_typeof(payload -> 'special_extra_config') = 'object' THEN
    v_special_extra_config := payload -> 'special_extra_config';
  ELSE
    v_special_extra_config := NULL;
  END IF;

  v_link_to_base_service_id :=
    NULLIF(payload ->> 'link_to_base_service_id', '')::uuid;

  v_include_in_summary := COALESCE((payload ->> 'include_in_quote_summary')::boolean, true);
  v_summary_group_override :=
    NULLIF(btrim(coalesce(payload ->> 'summary_group_override', '')), '');
  v_admin_notes := NULLIF(btrim(coalesce(payload ->> 'admin_notes', '')), '');

  -- Convert visible_roles JSON array to text[]; default to empty array.
  IF (payload ? 'visible_roles')
     AND jsonb_typeof(payload -> 'visible_roles') = 'array' THEN
    SELECT coalesce(array_agg(elem), ARRAY[]::text[])
      INTO v_visible_roles
      FROM jsonb_array_elements_text(payload -> 'visible_roles') AS elem;
  ELSE
    v_visible_roles := ARRAY[]::text[];
  END IF;

  v_role_prices := coalesce(payload -> 'role_prices', '[]'::jsonb);
  v_options     := coalesce(payload -> 'options',     '[]'::jsonb);
  IF jsonb_typeof(v_role_prices) <> 'array' THEN
    RAISE EXCEPTION 'save_quote_service: role_prices must be an array';
  END IF;
  IF jsonb_typeof(v_options) <> 'array' THEN
    RAISE EXCEPTION 'save_quote_service: options must be an array';
  END IF;

  -- Load existing service (if editing) and fall back to its section when
  -- section_id is not supplied. Required on create.
  IF v_id IS NOT NULL THEN
    SELECT * INTO v_existing FROM public.quote_services WHERE id = v_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'save_quote_service: service % not found', v_id;
    END IF;
    IF v_section_id IS NULL THEN
      v_section_id := v_existing.section_id;
    END IF;
  END IF;
  IF v_section_id IS NULL THEN
    RAISE EXCEPTION 'save_quote_service: section_id is required';
  END IF;

  -- display_order defaults to max+1 within the target section on create or
  -- when not supplied on edit.
  IF (payload ? 'display_order')
     AND NULLIF(payload ->> 'display_order', '') IS NOT NULL THEN
    v_display_order := (payload ->> 'display_order')::integer;
  ELSIF v_id IS NOT NULL THEN
    v_display_order := v_existing.display_order;
  ELSE
    SELECT COALESCE(MAX(display_order), 0) + 1
      INTO v_display_order
      FROM public.quote_services
      WHERE section_id = v_section_id;
  END IF;

  -- Upsert the service row itself.
  IF v_id IS NULL THEN
    INSERT INTO public.quote_services (
      section_id, name, internal_key, active, display_order,
      help_text, summary_label_override,
      input_type, pricing_type, visible_roles,
      fixed_price, numeric_config, extra_unit_config, special_extra_config,
      link_to_base_service_id,
      include_in_quote_summary, summary_group_override, admin_notes
    ) VALUES (
      v_section_id, v_name, v_internal_key, v_active, v_display_order,
      v_help_text, v_summary_label_override,
      v_input_type, v_pricing_type, v_visible_roles,
      v_fixed_price, v_numeric_config, v_extra_unit_config, v_special_extra_config,
      v_link_to_base_service_id,
      v_include_in_summary, v_summary_group_override, v_admin_notes
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE public.quote_services SET
      section_id               = v_section_id,
      name                     = v_name,
      internal_key             = v_internal_key,
      active                   = v_active,
      display_order            = v_display_order,
      help_text                = v_help_text,
      summary_label_override   = v_summary_label_override,
      input_type               = v_input_type,
      pricing_type             = v_pricing_type,
      visible_roles            = v_visible_roles,
      fixed_price              = v_fixed_price,
      numeric_config           = v_numeric_config,
      extra_unit_config        = v_extra_unit_config,
      special_extra_config     = v_special_extra_config,
      link_to_base_service_id  = v_link_to_base_service_id,
      include_in_quote_summary = v_include_in_summary,
      summary_group_override   = v_summary_group_override,
      admin_notes              = v_admin_notes
    WHERE id = v_id;
  END IF;

  -- Reconcile role prices: delete any rows for roles not in the incoming set
  -- (these rows never carry saved-quote references, so it is safe to delete),
  -- then upsert one row per incoming entry.
  DELETE FROM public.quote_service_role_prices
    WHERE service_id = v_id
      AND role NOT IN (
        SELECT (r ->> 'role')
          FROM jsonb_array_elements(v_role_prices) AS r
          WHERE NULLIF(btrim(r ->> 'role'), '') IS NOT NULL
      );

  INSERT INTO public.quote_service_role_prices (service_id, role, price)
  SELECT v_id,
         btrim(r ->> 'role'),
         COALESCE(NULLIF(r ->> 'price', '')::numeric(10, 2), 0)
    FROM jsonb_array_elements(v_role_prices) AS r
    WHERE NULLIF(btrim(r ->> 'role'), '') IS NOT NULL
  ON CONFLICT (service_id, role) DO UPDATE
    SET price = EXCLUDED.price;

  -- Reconcile options: collect incoming server-side ids (rows without id are
  -- treated as new inserts), delete anything on the service not in that set
  -- (fires the hard-delete gate if used in saved quotes), then upsert.
  SELECT COALESCE(
           array_agg(NULLIF(o ->> 'id', '')::uuid)
             FILTER (WHERE NULLIF(o ->> 'id', '') IS NOT NULL),
           ARRAY[]::uuid[])
    INTO v_incoming_option_ids
    FROM jsonb_array_elements(v_options) AS o;

  DELETE FROM public.quote_service_options
    WHERE service_id = v_id
      AND NOT (id = ANY (v_incoming_option_ids));

  FOR v_option IN SELECT * FROM jsonb_array_elements(v_options) LOOP
    v_option_id := NULLIF(v_option ->> 'id', '')::uuid;
    IF v_option_id IS NULL THEN
      INSERT INTO public.quote_service_options (
        service_id, label, value_key, display_order, active, price
      ) VALUES (
        v_id,
        btrim(v_option ->> 'label'),
        btrim(v_option ->> 'value_key'),
        COALESCE((v_option ->> 'display_order')::integer, 1),
        COALESCE((v_option ->> 'active')::boolean, true),
        NULLIF(v_option ->> 'price', '')::numeric(10, 2)
      );
    ELSE
      UPDATE public.quote_service_options SET
        label         = btrim(v_option ->> 'label'),
        value_key     = btrim(v_option ->> 'value_key'),
        display_order = COALESCE((v_option ->> 'display_order')::integer, display_order),
        active        = COALESCE((v_option ->> 'active')::boolean, active),
        price         = NULLIF(v_option ->> 'price', '')::numeric(10, 2)
      WHERE id = v_option_id
        AND service_id = v_id;
    END IF;
  END LOOP;

  RETURN v_id;
END;
$fn$;

ALTER FUNCTION public.save_quote_service(jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.save_quote_service(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_quote_service(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_quote_service(jsonb) TO service_role;


-- ---------------------------------------------------------------------------
-- delete_quote_section(p_section_id uuid)
--
-- Cascades the section delete: first deletes every service in the section
-- (which cascades options and role prices via FK ON DELETE CASCADE), then
-- deletes the section. Runs as a single transaction so a partial delete never
-- leaves orphaned services behind. If any service / option / the section
-- itself is referenced by a saved quote, the hard-delete gate raises a
-- `quote_*_used_in_saved_quotes` exception and the whole function rolls back.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_quote_section(p_section_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
BEGIN
  IF NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'delete_quote_section: not authorized'
      USING ERRCODE = '42501';
  END IF;

  IF p_section_id IS NULL THEN
    RAISE EXCEPTION 'delete_quote_section: section id is required';
  END IF;

  DELETE FROM public.quote_services WHERE section_id = p_section_id;
  DELETE FROM public.quote_sections WHERE id = p_section_id;
END;
$fn$;

ALTER FUNCTION public.delete_quote_section(uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.delete_quote_section(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_quote_section(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_quote_section(uuid) TO service_role;
