-- Single transactional entry point for saving a guest quote.
-- Validates the payload against live quote config, recomputes every price
-- server-side, stamps stylist_user_id = auth.uid(), and atomically inserts:
--   public.saved_quotes
--   public.saved_quote_lines
--   public.saved_quote_line_options
--   public.saved_quote_section_totals
-- Returns the new saved_quotes.id.
--
-- Payload shape (minimum):
-- {
--   "guest_name":            text | null,
--   "notes":                 text | null,
--   "quote_date":            "YYYY-MM-DD" | null,
--   "stylist_display_name":  text | null,          -- fallback when not derivable from staff_members
--   "lines": [
--     {
--       "service_id":            uuid (required),
--       "selected_role":         "EMERGING"|"SENIOR"|"DIRECTOR"|"MASTER" | null,
--       "selected_option_ids":   [uuid, ...]  | null,
--       "numeric_quantity":      number       | null,
--       "extra_units_selected":  integer      | null,
--       "special_extra_rows":    jsonb array  | null
--     }, ...
--   ]
-- }

CREATE OR REPLACE FUNCTION public.save_guest_quote(payload jsonb)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_user_id                 uuid;
  v_settings                public.quote_settings%ROWTYPE;
  v_settings_snapshot       jsonb;

  v_guest_name              text;
  v_notes                   text;
  v_quote_date              date;

  v_stylist_display_name    text;
  v_stylist_staff_member_id uuid;
  v_derived_display_name    text;

  v_saved_quote_id          uuid;

  v_lines                   jsonb;
  v_line                    jsonb;
  v_line_index              integer;
  v_line_id                 uuid;

  v_service_id              uuid;
  v_selected_role           text;
  v_selected_option_ids     uuid[];
  v_selected_option_id      uuid;
  v_numeric_quantity        numeric(12, 2);
  v_extra_units_selected    integer;
  v_special_extra_rows      jsonb;

  v_service                 public.quote_services%ROWTYPE;
  v_section                 public.quote_sections%ROWTYPE;
  v_option_rec              public.quote_service_options%ROWTYPE;
  v_role_price              numeric(10, 2);

  v_unit_price              numeric(10, 2);
  v_line_total              numeric(12, 2);

  v_include_in_summary      boolean;
  v_summary_group           text;
  v_config_snapshot         jsonb;

  v_special_row             jsonb;
  v_special_row_units       numeric;
  v_special_total_units     numeric;

  v_grand_total             numeric(12, 2);
BEGIN
  -- 1. Auth.
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'save_guest_quote: not authorized'
      USING ERRCODE = '28000';
  END IF;

  -- 2. Load settings singleton.
  SELECT * INTO v_settings FROM public.quote_settings WHERE id = 1;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'save_guest_quote: quote_settings has not been initialised';
  END IF;

  -- Safest MVP behaviour: if the Guest Quote page is globally inactive,
  -- nobody (including admins) can save from it via this RPC. Admins can flip
  -- the toggle in Quote Configuration if they need to unblock.
  IF v_settings.active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'save_guest_quote: guest quote is not active';
  END IF;

  v_settings_snapshot := jsonb_build_object(
    'green_fee_amount',    v_settings.green_fee_amount,
    'notes_enabled',       v_settings.notes_enabled,
    'guest_name_required', v_settings.guest_name_required,
    'quote_page_title',    v_settings.quote_page_title,
    'active',              v_settings.active
  );

  -- 3. Extract header scalars.
  v_guest_name := NULLIF(btrim(coalesce(payload ->> 'guest_name', '')), '');
  v_notes      := NULLIF(btrim(coalesce(payload ->> 'notes', '')), '');
  v_quote_date := COALESCE(NULLIF(payload ->> 'quote_date', '')::date, current_date);
  v_lines      := payload -> 'lines';

  IF v_lines IS NULL
     OR jsonb_typeof(v_lines) <> 'array'
     OR jsonb_array_length(v_lines) = 0 THEN
    RAISE EXCEPTION 'save_guest_quote: lines is required and must be a non-empty array';
  END IF;

  IF v_settings.guest_name_required AND v_guest_name IS NULL THEN
    RAISE EXCEPTION 'save_guest_quote: guest_name is required';
  END IF;

  -- Silently drop notes rather than reject when notes are globally disabled.
  IF v_settings.notes_enabled IS DISTINCT FROM true THEN
    v_notes := NULL;
  END IF;

  -- 4. Derive stylist identity. Prefer the server-side staff member record;
  -- fall back to the payload's stylist_display_name only when no linkage
  -- exists.
  SELECT sma.staff_member_id,
         NULLIF(btrim(coalesce(sm.display_name, sm.full_name, '')), '')
    INTO v_stylist_staff_member_id, v_derived_display_name
    FROM public.staff_member_user_access sma
    LEFT JOIN public.staff_members sm ON sm.id = sma.staff_member_id
    WHERE sma.user_id = v_user_id
      AND sma.is_active = true
    ORDER BY sma.created_at DESC NULLS LAST
    LIMIT 1;

  v_stylist_display_name := COALESCE(
    v_derived_display_name,
    NULLIF(btrim(coalesce(payload ->> 'stylist_display_name', '')), '')
  );

  IF v_stylist_display_name IS NULL THEN
    RAISE EXCEPTION 'save_guest_quote: could not determine stylist_display_name';
  END IF;

  -- 5. Insert header with placeholder grand_total (fixed up after lines).
  INSERT INTO public.saved_quotes (
    guest_name,
    stylist_user_id,
    stylist_staff_member_id,
    stylist_display_name,
    quote_date,
    notes,
    grand_total,
    green_fee_applied,
    settings_snapshot
  ) VALUES (
    v_guest_name,
    v_user_id,
    v_stylist_staff_member_id,
    v_stylist_display_name,
    v_quote_date,
    v_notes,
    0,
    v_settings.green_fee_amount,
    v_settings_snapshot
  )
  RETURNING id INTO v_saved_quote_id;

  -- 6. Process each line.
  FOR v_line_index IN 0 .. jsonb_array_length(v_lines) - 1 LOOP
    v_line := v_lines -> v_line_index;

    IF jsonb_typeof(v_line) <> 'object' THEN
      RAISE EXCEPTION 'save_guest_quote: line[%] is not an object', v_line_index;
    END IF;

    v_service_id := NULLIF(v_line ->> 'service_id', '')::uuid;
    IF v_service_id IS NULL THEN
      RAISE EXCEPTION 'save_guest_quote: line[%] is missing service_id', v_line_index;
    END IF;

    SELECT * INTO v_service FROM public.quote_services WHERE id = v_service_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'save_guest_quote: line[%] service % not found', v_line_index, v_service_id;
    END IF;
    IF v_service.active IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'save_guest_quote: line[%] service % is archived', v_line_index, v_service_id;
    END IF;

    SELECT * INTO v_section FROM public.quote_sections WHERE id = v_service.section_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'save_guest_quote: line[%] section % not found', v_line_index, v_service.section_id;
    END IF;
    IF v_section.active IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'save_guest_quote: line[%] section % is archived', v_line_index, v_section.id;
    END IF;

    -- Per-line payload fields. Kept nullable; only the fields relevant to the
    -- service's pricing_type are consulted below.
    v_selected_role        := NULLIF(v_line ->> 'selected_role', '');
    v_numeric_quantity     := NULLIF(v_line ->> 'numeric_quantity', '')::numeric(12, 2);
    v_extra_units_selected := NULLIF(v_line ->> 'extra_units_selected', '')::integer;
    v_special_extra_rows   := v_line -> 'special_extra_rows';

    v_selected_option_ids := NULL;
    IF (v_line ? 'selected_option_ids')
       AND jsonb_typeof(v_line -> 'selected_option_ids') = 'array' THEN
      SELECT array_agg((elem)::uuid)
        INTO v_selected_option_ids
        FROM jsonb_array_elements_text(v_line -> 'selected_option_ids') AS elem;

      -- Duplicate ids in the same line are always a client bug: reject early.
      IF v_selected_option_ids IS NOT NULL
         AND cardinality(v_selected_option_ids)
             <> (SELECT count(DISTINCT e) FROM unnest(v_selected_option_ids) AS e) THEN
        RAISE EXCEPTION 'save_guest_quote: line[%] selected_option_ids contains duplicate ids',
          v_line_index;
      END IF;
    END IF;

    v_unit_price := NULL;
    v_line_total := 0;

    -- 7. Price the line from live config by pricing_type.
    CASE v_service.pricing_type
      WHEN 'fixed_price' THEN
        IF v_service.fixed_price IS NULL THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] fixed_price is not configured', v_line_index;
        END IF;
        v_unit_price := v_service.fixed_price;
        v_line_total := v_service.fixed_price;

      WHEN 'role_price' THEN
        IF v_selected_role IS NULL THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] selected_role is required for role_price', v_line_index;
        END IF;
        IF NOT (v_selected_role = ANY (v_service.visible_roles)) THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] selected_role % is not in visible_roles',
            v_line_index, v_selected_role;
        END IF;
        SELECT price INTO v_role_price
          FROM public.quote_service_role_prices
          WHERE service_id = v_service.id AND role = v_selected_role;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] no role price found for role %',
            v_line_index, v_selected_role;
        END IF;
        v_unit_price := v_role_price;
        v_line_total := v_role_price;

      WHEN 'option_price' THEN
        IF v_selected_option_ids IS NULL OR array_length(v_selected_option_ids, 1) IS NULL THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] selected_option_ids is required for option_price', v_line_index;
        END IF;
        IF array_length(v_selected_option_ids, 1) <> 1 THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] option_price currently supports exactly one selected option (got %)',
            v_line_index, array_length(v_selected_option_ids, 1);
        END IF;
        v_selected_option_id := v_selected_option_ids[1];
        SELECT * INTO v_option_rec
          FROM public.quote_service_options
          WHERE id = v_selected_option_id AND service_id = v_service.id;
        IF NOT FOUND THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] option % does not belong to service %',
            v_line_index, v_selected_option_id, v_service.id;
        END IF;
        IF v_option_rec.active IS DISTINCT FROM true THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] option % is archived',
            v_line_index, v_selected_option_id;
        END IF;
        IF v_option_rec.price IS NULL THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] option % has no price',
            v_line_index, v_selected_option_id;
        END IF;
        v_unit_price := v_option_rec.price;
        v_line_total := v_option_rec.price;

      WHEN 'numeric_multiplier' THEN
        IF v_service.numeric_config IS NULL THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] numeric_config is missing', v_line_index;
        END IF;
        IF v_numeric_quantity IS NULL THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] numeric_quantity is required for numeric_multiplier', v_line_index;
        END IF;
        IF v_numeric_quantity < 0 THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] numeric_quantity must be >= 0 (got %)',
            v_line_index, v_numeric_quantity;
        END IF;
        IF v_numeric_quantity < (v_service.numeric_config ->> 'min')::numeric
           OR v_numeric_quantity > (v_service.numeric_config ->> 'max')::numeric THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] numeric_quantity % is outside configured range [%, %]',
            v_line_index, v_numeric_quantity,
            v_service.numeric_config ->> 'min', v_service.numeric_config ->> 'max';
        END IF;
        v_unit_price := (v_service.numeric_config ->> 'pricePerUnit')::numeric(10, 2);
        v_line_total := round(v_unit_price * v_numeric_quantity, 2);
        IF COALESCE((v_service.numeric_config ->> 'minCharge')::numeric, 0) > v_line_total THEN
          v_line_total := (v_service.numeric_config ->> 'minCharge')::numeric;
        END IF;

      WHEN 'extra_unit_price' THEN
        IF v_service.extra_unit_config IS NULL THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] extra_unit_config is missing', v_line_index;
        END IF;
        IF v_extra_units_selected IS NULL THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] extra_units_selected is required for extra_unit_price', v_line_index;
        END IF;
        IF v_extra_units_selected < 0
           OR v_extra_units_selected > (v_service.extra_unit_config ->> 'maxExtras')::integer THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] extra_units_selected % is outside allowed range [0, %]',
            v_line_index, v_extra_units_selected, v_service.extra_unit_config ->> 'maxExtras';
        END IF;
        v_unit_price := (v_service.extra_unit_config ->> 'pricePerExtraUnit')::numeric(10, 2);
        v_line_total := round(v_unit_price * v_extra_units_selected, 2);

      WHEN 'special_extra_product' THEN
        IF v_service.special_extra_config IS NULL THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] special_extra_config is missing', v_line_index;
        END IF;
        IF v_special_extra_rows IS NULL OR jsonb_typeof(v_special_extra_rows) <> 'array' THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] special_extra_rows must be an array', v_line_index;
        END IF;
        IF jsonb_array_length(v_special_extra_rows)
             > (v_service.special_extra_config ->> 'numberOfRows')::integer THEN
          RAISE EXCEPTION 'save_guest_quote: line[%] special_extra_rows count % exceeds configured numberOfRows %',
            v_line_index,
            jsonb_array_length(v_special_extra_rows),
            v_service.special_extra_config ->> 'numberOfRows';
        END IF;
        v_special_total_units := 0;
        FOR v_special_row IN SELECT * FROM jsonb_array_elements(v_special_extra_rows) LOOP
          v_special_row_units := COALESCE((v_special_row ->> 'units')::numeric, 0);
          IF v_special_row_units < 0
             OR v_special_row_units > (v_service.special_extra_config ->> 'maxUnitsPerRow')::numeric THEN
            RAISE EXCEPTION 'save_guest_quote: line[%] special_extra_rows units % outside allowed per-row range [0, %]',
              v_line_index, v_special_row_units,
              v_service.special_extra_config ->> 'maxUnitsPerRow';
          END IF;
          v_special_total_units := v_special_total_units + v_special_row_units;
        END LOOP;
        v_unit_price := (v_service.special_extra_config ->> 'pricePerUnit')::numeric(10, 2);
        v_line_total := round(v_unit_price * v_special_total_units, 2);

      ELSE
        RAISE EXCEPTION 'save_guest_quote: line[%] unsupported pricing_type %',
          v_line_index, v_service.pricing_type;
    END CASE;

    -- 8. Derive summary routing + build the config_snapshot for the line.
    v_include_in_summary := COALESCE(v_service.include_in_quote_summary, true);
    v_summary_group := COALESCE(
      NULLIF(btrim(coalesce(v_service.summary_label_override, '')), ''),
      NULLIF(btrim(coalesce(v_service.summary_group_override, '')), ''),
      v_section.summary_label
    );

    v_config_snapshot := jsonb_build_object(
      'visible_roles',            v_service.visible_roles,
      'fixed_price',              v_service.fixed_price,
      'numeric_config',           v_service.numeric_config,
      'extra_unit_config',        v_service.extra_unit_config,
      'special_extra_config',     v_service.special_extra_config,
      'summary_label_override',   v_service.summary_label_override,
      'summary_group_override',   v_service.summary_group_override,
      'include_in_quote_summary', v_service.include_in_quote_summary,
      'help_text',                v_service.help_text,
      'link_to_base_service_id',  v_service.link_to_base_service_id
    );

    IF v_service.pricing_type = 'role_price' THEN
      v_config_snapshot := v_config_snapshot || jsonb_build_object(
        'role_prices',
        (SELECT coalesce(jsonb_object_agg(role, price), '{}'::jsonb)
           FROM public.quote_service_role_prices
           WHERE service_id = v_service.id)
      );
    END IF;

    IF v_service.input_type IN ('option_radio', 'dropdown')
       OR v_service.pricing_type = 'option_price' THEN
      v_config_snapshot := v_config_snapshot || jsonb_build_object(
        'options',
        (SELECT coalesce(jsonb_agg(
            jsonb_build_object(
              'id',            o.id,
              'label',         o.label,
              'value_key',     o.value_key,
              'display_order', o.display_order,
              'active',        o.active,
              'price',         o.price
            ) ORDER BY o.display_order), '[]'::jsonb)
          FROM public.quote_service_options o
          WHERE o.service_id = v_service.id)
      );
    END IF;

    -- 9. Insert the line row.
    INSERT INTO public.saved_quote_lines (
      saved_quote_id,
      line_order,
      service_id,
      section_id,
      section_name_snapshot,
      section_summary_label_snapshot,
      service_name_snapshot,
      service_internal_key_snapshot,
      input_type_snapshot,
      pricing_type_snapshot,
      selected_role,
      numeric_quantity,
      numeric_unit_label_snapshot,
      extra_units_selected,
      special_extra_rows_snapshot,
      unit_price_snapshot,
      line_total,
      include_in_summary_snapshot,
      summary_group_snapshot,
      config_snapshot
    ) VALUES (
      v_saved_quote_id,
      v_line_index + 1,
      v_service.id,
      v_section.id,
      v_section.name,
      v_section.summary_label,
      v_service.name,
      v_service.internal_key,
      v_service.input_type,
      v_service.pricing_type,
      CASE WHEN v_service.pricing_type = 'role_price'          THEN v_selected_role        END,
      CASE WHEN v_service.pricing_type = 'numeric_multiplier'  THEN v_numeric_quantity     END,
      CASE WHEN v_service.pricing_type = 'numeric_multiplier'
           THEN v_service.numeric_config ->> 'unitLabel'
      END,
      CASE WHEN v_service.pricing_type = 'extra_unit_price'    THEN v_extra_units_selected END,
      CASE WHEN v_service.pricing_type = 'special_extra_product' THEN v_special_extra_rows END,
      v_unit_price,
      v_line_total,
      v_include_in_summary,
      v_summary_group,
      v_config_snapshot
    )
    RETURNING id INTO v_line_id;

    -- 10. Snapshot selected options. Only option-input services persist rows
    -- in saved_quote_line_options; submitted option ids on unrelated services
    -- are intentionally ignored so we never "blindly snapshot" for a service
    -- whose input_type has nothing to do with options.
    IF v_selected_option_ids IS NOT NULL
       AND array_length(v_selected_option_ids, 1) >= 1
       AND v_service.input_type IN ('option_radio', 'dropdown') THEN

      -- Every submitted id must map to an active option on this service.
      IF (SELECT count(*)
            FROM public.quote_service_options o
            WHERE o.id = ANY (v_selected_option_ids)
              AND o.service_id = v_service.id
              AND o.active = true)
         <> array_length(v_selected_option_ids, 1) THEN
        RAISE EXCEPTION
          'save_guest_quote: line[%] one or more selected_option_ids do not belong to service % or are archived',
          v_line_index, v_service.id;
      END IF;

      INSERT INTO public.saved_quote_line_options (
        saved_quote_line_id,
        service_option_id,
        option_label_snapshot,
        option_value_key_snapshot,
        option_price_snapshot
      )
      SELECT v_line_id, o.id, o.label, o.value_key, o.price
        FROM public.quote_service_options o
        WHERE o.id = ANY (v_selected_option_ids)
          AND o.service_id = v_service.id
          AND o.active = true
        ORDER BY o.display_order;
    END IF;
  END LOOP;

  -- 11. Section totals: one row per section with any summary-included lines.
  INSERT INTO public.saved_quote_section_totals (
    saved_quote_id,
    display_order,
    section_summary_label_snapshot,
    section_name_snapshot,
    section_total
  )
  SELECT
    v_saved_quote_id,
    sec.display_order,
    sec.summary_label,
    sec.name,
    COALESCE(SUM(l.line_total) FILTER (WHERE l.include_in_summary_snapshot), 0)
  FROM public.saved_quote_lines l
  JOIN public.quote_sections sec ON sec.id = l.section_id
  WHERE l.saved_quote_id = v_saved_quote_id
  GROUP BY sec.id, sec.display_order, sec.summary_label, sec.name
  HAVING COALESCE(SUM(l.line_total) FILTER (WHERE l.include_in_summary_snapshot), 0) > 0;

  -- 12. Grand total = Σ summary-included line totals + green fee.
  SELECT COALESCE(SUM(line_total) FILTER (WHERE include_in_summary_snapshot), 0)
    INTO v_grand_total
    FROM public.saved_quote_lines
    WHERE saved_quote_id = v_saved_quote_id;

  v_grand_total := v_grand_total + v_settings.green_fee_amount;

  UPDATE public.saved_quotes
    SET grand_total = v_grand_total
    WHERE id = v_saved_quote_id;

  RETURN v_saved_quote_id;
END;
$fn$;

ALTER FUNCTION public.save_guest_quote(jsonb) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.save_guest_quote(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_guest_quote(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.save_guest_quote(jsonb) TO service_role;
