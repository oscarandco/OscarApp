-- Read-only, stylist-facing entry point for the Guest Quote page.
--
-- public.get_active_quote_config() returns a single JSONB object containing:
--   * quote_settings (singleton row)
--   * active quote_sections ordered by display_order
--   * active quote_services nested under their section, ordered by display_order
--   * active quote_service_options for each service, ordered by display_order
--   * all quote_service_role_prices for each service, keyed by role
--
-- Authorization: auth.uid() must be non-null. The function is SECURITY DEFINER
-- so it can read the RLS-protected tables on behalf of any authenticated user
-- without broadening direct table-select grants beyond elevated access.
--
-- Admin-only edit metadata intentionally omitted: created_at/updated_at on
-- every row, `active` flags (rows are already filtered), admin_notes, and the
-- `active` flag on options (ditto).
--
-- Shape:
-- {
--   "settings": {
--     "green_fee_amount": numeric,
--     "notes_enabled": bool,
--     "guest_name_required": bool,
--     "quote_page_title": text,
--     "active": bool
--   },
--   "sections": [
--     {
--       "id": uuid,
--       "name": text,
--       "summary_label": text,
--       "display_order": int,
--       "section_help_text": text | null,
--       "services": [
--         {
--           "id": uuid,
--           "section_id": uuid,
--           "name": text,
--           "internal_key": text | null,
--           "display_order": int,
--           "help_text": text | null,
--           "summary_label_override": text | null,
--           "input_type": text,
--           "pricing_type": text,
--           "visible_roles": [text, ...],
--           "fixed_price": numeric | null,
--           "numeric_config": jsonb | null,
--           "extra_unit_config": jsonb | null,
--           "special_extra_config": jsonb | null,
--           "link_to_base_service_id": uuid | null,
--           "include_in_quote_summary": bool,
--           "summary_group_override": text | null,
--           "options": [
--             { "id": uuid, "label": text, "value_key": text,
--               "display_order": int, "price": numeric | null }, ...
--           ],
--           "role_prices": { "EMERGING": numeric, "SENIOR": numeric, ... }
--         }, ...
--       ]
--     }, ...
--   ]
-- }

CREATE OR REPLACE FUNCTION public.get_active_quote_config()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_user_id  uuid;
  v_settings jsonb;
  v_sections jsonb;
BEGIN
  -- Require an authenticated session. Non-authenticated reads are forbidden.
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'get_active_quote_config: not authorized'
      USING ERRCODE = '28000';
  END IF;

  SELECT jsonb_build_object(
           'green_fee_amount',    green_fee_amount,
           'notes_enabled',       notes_enabled,
           'guest_name_required', guest_name_required,
           'quote_page_title',    quote_page_title,
           'active',              active
         )
    INTO v_settings
    FROM public.quote_settings
    WHERE id = 1;

  -- If quote_settings has never been initialised, return a safe "disabled"
  -- stub rather than NULL. The stylist page can render a friendly message.
  IF v_settings IS NULL THEN
    v_settings := jsonb_build_object(
      'green_fee_amount',    0,
      'notes_enabled',       true,
      'guest_name_required', false,
      'quote_page_title',    'Guest Quote',
      'active',              false
    );
  END IF;

  -- Build the nested sections/services/options/role_prices tree in one pass.
  -- LATERAL joins keep the correlation to the outer section/service explicit
  -- and let each inner jsonb_agg sort by display_order without needing a
  -- separate GROUP BY.
  SELECT COALESCE(
           jsonb_agg(
             jsonb_build_object(
               'id',                s.id,
               'name',              s.name,
               'summary_label',     s.summary_label,
               'display_order',     s.display_order,
               'section_help_text', s.section_help_text,
               'services',          COALESCE(svc_list.services, '[]'::jsonb)
             )
             ORDER BY s.display_order
           ),
           '[]'::jsonb
         )
    INTO v_sections
    FROM public.quote_sections s
    LEFT JOIN LATERAL (
      SELECT jsonb_agg(
               jsonb_build_object(
                 'id',                       svc.id,
                 'section_id',               svc.section_id,
                 'name',                     svc.name,
                 'internal_key',             svc.internal_key,
                 'display_order',            svc.display_order,
                 'help_text',                svc.help_text,
                 'summary_label_override',   svc.summary_label_override,
                 'input_type',               svc.input_type,
                 'pricing_type',             svc.pricing_type,
                 'visible_roles',            to_jsonb(svc.visible_roles),
                 'fixed_price',              svc.fixed_price,
                 'numeric_config',           svc.numeric_config,
                 'extra_unit_config',        svc.extra_unit_config,
                 'special_extra_config',     svc.special_extra_config,
                 'link_to_base_service_id',  svc.link_to_base_service_id,
                 'include_in_quote_summary', svc.include_in_quote_summary,
                 'summary_group_override',   svc.summary_group_override,
                 'options',                  COALESCE(opt_list.options, '[]'::jsonb),
                 'role_prices',              COALESCE(rp_obj.role_prices, '{}'::jsonb)
               )
               ORDER BY svc.display_order
             ) AS services
        FROM public.quote_services svc
        LEFT JOIN LATERAL (
          SELECT jsonb_agg(
                   jsonb_build_object(
                     'id',            opt.id,
                     'label',         opt.label,
                     'value_key',     opt.value_key,
                     'display_order', opt.display_order,
                     'price',         opt.price
                   )
                   ORDER BY opt.display_order
                 ) AS options
            FROM public.quote_service_options opt
            WHERE opt.service_id = svc.id
              AND opt.active = true
        ) opt_list ON true
        LEFT JOIN LATERAL (
          SELECT jsonb_object_agg(rp.role, rp.price) AS role_prices
            FROM public.quote_service_role_prices rp
            WHERE rp.service_id = svc.id
        ) rp_obj ON true
        WHERE svc.section_id = s.id
          AND svc.active = true
    ) svc_list ON true
    WHERE s.active = true;

  RETURN jsonb_build_object(
    'settings', v_settings,
    'sections', v_sections
  );
END;
$fn$;

ALTER FUNCTION public.get_active_quote_config() OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_active_quote_config() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_active_quote_config() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_active_quote_config() TO service_role;

COMMENT ON FUNCTION public.get_active_quote_config() IS
  'Read-only stylist-facing entry point. Returns a JSON tree of active quote '
  'settings + sections + services + options + role prices. Requires '
  'auth.uid() to be non-null; bypasses RLS via SECURITY DEFINER so stylists '
  'do not need direct table read access.';
