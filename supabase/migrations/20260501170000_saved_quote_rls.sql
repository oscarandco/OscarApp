-- Saved quote RLS and grants.
-- Saved quotes are readable by elevated users across all quotes and by the
-- stylist who created them. Stylists can insert as themselves. No UPDATE or
-- DELETE is granted to authenticated; saved quotes are immutable from the app.
-- Child rows inherit visibility/ownership from their parent saved_quote.

-- 1. Grants. SELECT + INSERT only. No UPDATE/DELETE. No anon.
GRANT SELECT, INSERT ON public.saved_quotes                TO authenticated;
GRANT SELECT, INSERT ON public.saved_quote_lines           TO authenticated;
GRANT SELECT, INSERT ON public.saved_quote_line_options    TO authenticated;
GRANT SELECT, INSERT ON public.saved_quote_section_totals  TO authenticated;

-- 2. Enable RLS.
ALTER TABLE public.saved_quotes                ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saved_quote_lines           ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saved_quote_line_options    ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.saved_quote_section_totals  ENABLE ROW LEVEL SECURITY;


-- 3. Policies on public.saved_quotes.
DROP POLICY IF EXISTS "saved_quotes_elevated_select" ON public.saved_quotes;
DROP POLICY IF EXISTS "saved_quotes_author_select"   ON public.saved_quotes;
DROP POLICY IF EXISTS "saved_quotes_author_insert"   ON public.saved_quotes;

CREATE POLICY "saved_quotes_elevated_select"
  ON public.saved_quotes
  FOR SELECT
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()));

CREATE POLICY "saved_quotes_author_select"
  ON public.saved_quotes
  FOR SELECT
  TO authenticated
  USING (stylist_user_id = auth.uid());

CREATE POLICY "saved_quotes_author_insert"
  ON public.saved_quotes
  FOR INSERT
  TO authenticated
  WITH CHECK (stylist_user_id = auth.uid());


-- 4. Policies on public.saved_quote_lines. Piggy-back on parent via EXISTS.
DROP POLICY IF EXISTS "saved_quote_lines_elevated_select" ON public.saved_quote_lines;
DROP POLICY IF EXISTS "saved_quote_lines_author_select"   ON public.saved_quote_lines;
DROP POLICY IF EXISTS "saved_quote_lines_author_insert"   ON public.saved_quote_lines;

CREATE POLICY "saved_quote_lines_elevated_select"
  ON public.saved_quote_lines
  FOR SELECT
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()));

CREATE POLICY "saved_quote_lines_author_select"
  ON public.saved_quote_lines
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.saved_quotes sq
      WHERE sq.id = saved_quote_lines.saved_quote_id
        AND sq.stylist_user_id = auth.uid()
    )
  );

CREATE POLICY "saved_quote_lines_author_insert"
  ON public.saved_quote_lines
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.saved_quotes sq
      WHERE sq.id = saved_quote_lines.saved_quote_id
        AND sq.stylist_user_id = auth.uid()
    )
  );


-- 5. Policies on public.saved_quote_line_options. Ownership is resolved
-- through saved_quote_lines → saved_quotes.
DROP POLICY IF EXISTS "saved_quote_line_options_elevated_select" ON public.saved_quote_line_options;
DROP POLICY IF EXISTS "saved_quote_line_options_author_select"   ON public.saved_quote_line_options;
DROP POLICY IF EXISTS "saved_quote_line_options_author_insert"   ON public.saved_quote_line_options;

CREATE POLICY "saved_quote_line_options_elevated_select"
  ON public.saved_quote_line_options
  FOR SELECT
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()));

CREATE POLICY "saved_quote_line_options_author_select"
  ON public.saved_quote_line_options
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1
      FROM public.saved_quote_lines sql_
      JOIN public.saved_quotes sq ON sq.id = sql_.saved_quote_id
      WHERE sql_.id = saved_quote_line_options.saved_quote_line_id
        AND sq.stylist_user_id = auth.uid()
    )
  );

CREATE POLICY "saved_quote_line_options_author_insert"
  ON public.saved_quote_line_options
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1
      FROM public.saved_quote_lines sql_
      JOIN public.saved_quotes sq ON sq.id = sql_.saved_quote_id
      WHERE sql_.id = saved_quote_line_options.saved_quote_line_id
        AND sq.stylist_user_id = auth.uid()
    )
  );


-- 6. Policies on public.saved_quote_section_totals.
DROP POLICY IF EXISTS "saved_quote_section_totals_elevated_select" ON public.saved_quote_section_totals;
DROP POLICY IF EXISTS "saved_quote_section_totals_author_select"   ON public.saved_quote_section_totals;
DROP POLICY IF EXISTS "saved_quote_section_totals_author_insert"   ON public.saved_quote_section_totals;

CREATE POLICY "saved_quote_section_totals_elevated_select"
  ON public.saved_quote_section_totals
  FOR SELECT
  TO authenticated
  USING ((SELECT private.user_has_elevated_access()));

CREATE POLICY "saved_quote_section_totals_author_select"
  ON public.saved_quote_section_totals
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.saved_quotes sq
      WHERE sq.id = saved_quote_section_totals.saved_quote_id
        AND sq.stylist_user_id = auth.uid()
    )
  );

CREATE POLICY "saved_quote_section_totals_author_insert"
  ON public.saved_quote_section_totals
  FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.saved_quotes sq
      WHERE sq.id = saved_quote_section_totals.saved_quote_id
        AND sq.stylist_user_id = auth.uid()
    )
  );
