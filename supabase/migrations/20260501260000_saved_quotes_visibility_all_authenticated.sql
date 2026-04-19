-- Saved quote read visibility opened up to all authenticated users.
--
-- Background
-- ----------
-- The Previous Quotes page initially restricted non-elevated users
-- (assistant / stylist) to seeing only their own saved quotes; elevated
-- users (manager / admin) saw everything. Per the latest product
-- requirement, assistants and stylists should also be able to read and
-- requote any saved quote — only DELETE remains restricted to the
-- quote's author for non-elevated users (delete_saved_quote already
-- enforces that and is left unchanged).
--
-- This migration broadens read access in the three places where the
-- old restriction lived:
--   1. public.get_saved_quotes_search  (the list RPC)
--   2. public.get_saved_quote_detail   (the detail RPC, used by both
--                                       the detail page and the
--                                       Previous Quotes "Requote" flow)
--   3. RLS on the four saved-quote tables (defence-in-depth so direct
--      SELECTs through PostgREST also see all rows, not just own)
--
-- Mutations are not touched:
--   - INSERT policies still require stylist_user_id = auth.uid()
--   - delete_saved_quote() still restricts non-elevated callers to
--     their own rows (that's what enforces the "delete only your own"
--     UI rule)
--   - No UPDATE is granted to authenticated anywhere.

-- ---------------------------------------------------------------------
-- 1. RPC: list page. Drop the (elevated OR own) filter; auth still
--    required.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_saved_quotes_search(
  p_search     text  DEFAULT NULL,
  p_stylist    text  DEFAULT NULL,
  p_guest_name text  DEFAULT NULL,
  p_date_from  date  DEFAULT NULL,
  p_date_to    date  DEFAULT NULL,
  p_limit      int   DEFAULT 100,
  p_offset     int   DEFAULT 0
)
RETURNS TABLE (
  id                   uuid,
  created_at           timestamptz,
  quote_date           date,
  guest_name           text,
  stylist_user_id      uuid,
  stylist_display_name text,
  notes_preview        text,
  grand_total          numeric(12, 2),
  line_count           bigint,
  total_count          bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_user_id uuid;
  v_limit   int;
  v_offset  int;
  v_search  text;
  v_stylist text;
  v_guest   text;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'get_saved_quotes_search: not authorized'
      USING ERRCODE = '28000';
  END IF;

  v_limit  := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);

  v_search  := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_stylist := NULLIF(btrim(COALESCE(p_stylist, '')), '');
  v_guest   := NULLIF(btrim(COALESCE(p_guest_name, '')), '');

  RETURN QUERY
  WITH scoped AS (
    SELECT sq.*
    FROM public.saved_quotes sq
    WHERE (p_date_from IS NULL OR sq.quote_date >= p_date_from)
      AND (p_date_to   IS NULL OR sq.quote_date <= p_date_to)
      AND (
        v_search IS NULL
        OR sq.guest_name           ILIKE '%' || v_search  || '%'
        OR sq.stylist_display_name ILIKE '%' || v_search  || '%'
      )
      AND (
        v_guest IS NULL
        OR sq.guest_name ILIKE '%' || v_guest || '%'
      )
      AND (
        v_stylist IS NULL
        OR sq.stylist_display_name ILIKE '%' || v_stylist || '%'
      )
  ),
  counted AS (
    SELECT count(*)::bigint AS n FROM scoped
  )
  SELECT
    s.id,
    s.created_at,
    s.quote_date,
    s.guest_name,
    s.stylist_user_id,
    s.stylist_display_name,
    CASE
      WHEN s.notes IS NULL                     THEN NULL
      WHEN length(btrim(s.notes)) = 0          THEN NULL
      WHEN length(s.notes) <= 120              THEN s.notes
      ELSE substr(s.notes, 1, 117) || '...'
    END AS notes_preview,
    s.grand_total,
    (
      SELECT count(*)::bigint
        FROM public.saved_quote_lines l
        WHERE l.saved_quote_id = s.id
    ) AS line_count,
    (SELECT n FROM counted) AS total_count
  FROM scoped s
  ORDER BY s.created_at DESC, s.id
  LIMIT v_limit
  OFFSET v_offset;
END;
$fn$;

-- ---------------------------------------------------------------------
-- 2. RPC: detail. Drop the (elevated OR own) gate; auth still required.
--    A missing row still raises P0002, so requote calls for a deleted
--    quote continue to surface the same generic not-found error.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_saved_quote_detail(p_saved_quote_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $fn$
DECLARE
  v_user_id uuid;
  v_quote   public.saved_quotes%ROWTYPE;
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

  SELECT * INTO v_quote
    FROM public.saved_quotes
    WHERE id = p_saved_quote_id;

  IF NOT FOUND THEN
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

-- ---------------------------------------------------------------------
-- 3. RLS: defence-in-depth. Add a generic authenticated SELECT policy
--    on each saved-quote table. Postgres treats multiple permissive
--    SELECT policies as OR'd, so the existing elevated/author policies
--    still apply but become redundant for SELECT — they remain in
--    place to keep the original migration's intent visible in the
--    schema. INSERT policies are NOT touched.
-- ---------------------------------------------------------------------
DROP POLICY IF EXISTS "saved_quotes_authenticated_select"
  ON public.saved_quotes;
CREATE POLICY "saved_quotes_authenticated_select"
  ON public.saved_quotes
  FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "saved_quote_lines_authenticated_select"
  ON public.saved_quote_lines;
CREATE POLICY "saved_quote_lines_authenticated_select"
  ON public.saved_quote_lines
  FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "saved_quote_line_options_authenticated_select"
  ON public.saved_quote_line_options;
CREATE POLICY "saved_quote_line_options_authenticated_select"
  ON public.saved_quote_line_options
  FOR SELECT
  TO authenticated
  USING (true);

DROP POLICY IF EXISTS "saved_quote_section_totals_authenticated_select"
  ON public.saved_quote_section_totals;
CREATE POLICY "saved_quote_section_totals_authenticated_select"
  ON public.saved_quote_section_totals
  FOR SELECT
  TO authenticated
  USING (true);
