-- Read RPC for the Previous Quotes page.
--
-- Design notes
-- ------------
-- RLS on public.saved_quotes already enforces that stylists only see their
-- own rows while elevated users see everything, but the Previous Quotes
-- page needs a single round trip with filters, pagination, a line count,
-- and a notes preview. That's best expressed as an RPC.
--
-- This RPC is SECURITY DEFINER and re-enforces the same access rule
-- server-side using private.user_has_elevated_access() plus auth.uid().
-- It deliberately does NOT broaden table access — authenticated already
-- has SELECT via RLS; the RPC simply centralises the read shape.
--
-- Access rule
--   - auth.uid() must be non-null
--   - elevated users see all quotes
--   - everyone else sees only rows where stylist_user_id = auth.uid()
--
-- Returned columns
--   id, created_at, quote_date, guest_name, stylist_user_id,
--   stylist_display_name, notes_preview, grand_total, line_count,
--   total_count (same value on every row — count of rows matching the
--   filter before LIMIT/OFFSET; enables simple pagination without a
--   second round trip).

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
  v_user_id  uuid;
  v_elevated boolean;
  v_limit    int;
  v_offset   int;
  v_search   text;
  v_stylist  text;
  v_guest    text;
BEGIN
  v_user_id := auth.uid();
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'get_saved_quotes_search: not authorized'
      USING ERRCODE = '28000';
  END IF;

  v_elevated := COALESCE((SELECT private.user_has_elevated_access()), false);

  -- Clamp pagination server-side so a misconfigured client cannot request
  -- a huge page.
  v_limit  := LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500);
  v_offset := GREATEST(COALESCE(p_offset, 0), 0);

  v_search  := NULLIF(btrim(COALESCE(p_search, '')), '');
  v_stylist := NULLIF(btrim(COALESCE(p_stylist, '')), '');
  v_guest   := NULLIF(btrim(COALESCE(p_guest_name, '')), '');

  RETURN QUERY
  WITH scoped AS (
    SELECT sq.*
    FROM public.saved_quotes sq
    WHERE (v_elevated OR sq.stylist_user_id = v_user_id)
      AND (p_date_from IS NULL OR sq.quote_date >= p_date_from)
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

ALTER FUNCTION public.get_saved_quotes_search(
  text, text, text, date, date, int, int
) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.get_saved_quotes_search(
  text, text, text, date, date, int, int
) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.get_saved_quotes_search(
  text, text, text, date, date, int, int
) TO authenticated;

GRANT EXECUTE ON FUNCTION public.get_saved_quotes_search(
  text, text, text, date, date, int, int
) TO service_role;
