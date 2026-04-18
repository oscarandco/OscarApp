-- Read RPC for the saved Quote Detail page.
--
-- Design notes
-- ------------
-- RLS on public.saved_quotes already enforces stylist-own vs elevated-all
-- visibility, but the detail page benefits from one round trip that
-- returns header + section totals + lines + selected options in a single
-- JSONB payload. This RPC keeps that shape consistent and re-enforces
-- access server-side.
--
-- Access rule (identical to get_saved_quotes_search):
--   - auth.uid() must be non-null
--   - elevated users can read any quote
--   - everyone else can only read quotes where stylist_user_id = auth.uid()
--
-- Not-found and access-denied raise the SAME generic error so callers
-- cannot distinguish between "quote does not exist" and "quote exists
-- but belongs to someone else".

CREATE OR REPLACE FUNCTION public.get_saved_quote_detail(p_saved_quote_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_user_id  uuid;
  v_elevated boolean;
  v_quote    public.saved_quotes%ROWTYPE;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'get_saved_quote_detail: not authorized'
      USING ERRCODE = '28000';
  END IF;

  IF p_saved_quote_id IS NULL THEN
    RAISE EXCEPTION 'get_saved_quote_detail: quote not found'
      USING ERRCODE = 'P0002';
  END IF;

  v_elevated := COALESCE((SELECT private.user_has_elevated_access()), false);

  SELECT * INTO v_quote
    FROM public.saved_quotes
    WHERE id = p_saved_quote_id;

  IF NOT FOUND
     OR (NOT v_elevated AND v_quote.stylist_user_id IS DISTINCT FROM v_user_id)
  THEN
    -- Generic not-found for both "missing" and "belongs to another
    -- stylist" so we never leak existence of inaccessible rows.
    RAISE EXCEPTION 'get_saved_quote_detail: quote not found'
      USING ERRCODE = 'P0002';
  END IF;

  RETURN jsonb_build_object(
    'header', jsonb_build_object(
      'id',                   v_quote.id,
      'created_at',           v_quote.created_at,
      'quote_date',           v_quote.quote_date,
      'guest_name',           v_quote.guest_name,
      'stylist_display_name', v_quote.stylist_display_name,
      'notes',                v_quote.notes,
      'grand_total',          v_quote.grand_total,
      'green_fee_applied',    v_quote.green_fee_applied
    ),
    'section_totals', COALESCE((
      SELECT jsonb_agg(
               jsonb_build_object(
                 'display_order',  t.display_order,
                 'section_name',   t.section_name_snapshot,
                 'summary_label',  t.section_summary_label_snapshot,
                 'section_total',  t.section_total
               )
               ORDER BY t.display_order
             )
        FROM public.saved_quote_section_totals t
        WHERE t.saved_quote_id = v_quote.id
    ), '[]'::jsonb),
    'lines', COALESCE((
      SELECT jsonb_agg(line_json ORDER BY line_order)
        FROM (
          SELECT
            l.line_order,
            jsonb_build_object(
              'id',                   l.id,
              'line_order',           l.line_order,
              'section_id',           l.section_id,
              'section_name',         l.section_name_snapshot,
              'section_summary_label', l.section_summary_label_snapshot,
              'service_name',         l.service_name_snapshot,
              'summary_group',        l.summary_group_snapshot,
              'input_type',           l.input_type_snapshot,
              'pricing_type',         l.pricing_type_snapshot,
              'selected_role',        l.selected_role,
              'numeric_quantity',     l.numeric_quantity,
              'numeric_unit_label',   l.numeric_unit_label_snapshot,
              'extra_units_selected', l.extra_units_selected,
              'special_extra_rows',   l.special_extra_rows_snapshot,
              'unit_price',           l.unit_price_snapshot,
              'line_total',           l.line_total,
              'include_in_summary',   l.include_in_summary_snapshot,
              'selected_options',     COALESCE((
                SELECT jsonb_agg(
                         jsonb_build_object(
                           'label',     o.option_label_snapshot,
                           'value_key', o.option_value_key_snapshot,
                           'price',     o.option_price_snapshot
                         )
                         ORDER BY o.option_label_snapshot
                       )
                  FROM public.saved_quote_line_options o
                  WHERE o.saved_quote_line_id = l.id
              ), '[]'::jsonb)
            ) AS line_json
          FROM public.saved_quote_lines l
          WHERE l.saved_quote_id = v_quote.id
        ) ranked
    ), '[]'::jsonb)
  );
END;
$fn$;

ALTER FUNCTION public.get_saved_quote_detail(uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.get_saved_quote_detail(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_saved_quote_detail(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_saved_quote_detail(uuid) TO service_role;
