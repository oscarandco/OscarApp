-- Delete RPC for saved quotes.
--
-- Design notes
-- ------------
-- Direct DELETE on public.saved_quotes is not granted to authenticated
-- (see 20260501170000_saved_quote_rls.sql). Delete is performed through
-- this SECURITY DEFINER RPC which re-enforces the same access rule used
-- by get_saved_quote_detail:
--
--   - auth.uid() must be non-null
--   - elevated users may delete any saved quote
--   - everyone else may delete only quotes where stylist_user_id = auth.uid()
--
-- Not-found and access-denied raise the SAME generic error so callers
-- cannot distinguish between "quote does not exist" and "quote exists
-- but belongs to someone else".
--
-- Child rows
-- ----------
-- public.saved_quote_lines.saved_quote_id            ON DELETE CASCADE
-- public.saved_quote_line_options.saved_quote_line_id ON DELETE CASCADE
-- public.saved_quote_section_totals.saved_quote_id   ON DELETE CASCADE
--
-- So a single DELETE on public.saved_quotes is sufficient — the FK
-- cascades clean up lines, their selected options, and section totals in
-- one transaction.

CREATE OR REPLACE FUNCTION public.delete_saved_quote(p_saved_quote_id uuid)
RETURNS void
LANGUAGE plpgsql
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
    RAISE EXCEPTION 'delete_saved_quote: not authorized'
      USING ERRCODE = '28000';
  END IF;

  IF p_saved_quote_id IS NULL THEN
    RAISE EXCEPTION 'delete_saved_quote: quote not found'
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
    RAISE EXCEPTION 'delete_saved_quote: quote not found'
      USING ERRCODE = 'P0002';
  END IF;

  DELETE FROM public.saved_quotes WHERE id = p_saved_quote_id;
END;
$fn$;

ALTER FUNCTION public.delete_saved_quote(uuid) OWNER TO postgres;

REVOKE ALL ON FUNCTION public.delete_saved_quote(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_saved_quote(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.delete_saved_quote(uuid) TO service_role;
