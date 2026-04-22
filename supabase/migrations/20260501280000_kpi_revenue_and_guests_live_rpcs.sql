-- =====================================================================
-- KPI live reporting foundation: caller-context helpers, embedded
-- regression tests for public.normalise_customer_name, and the first
-- two live KPI RPCs (revenue, guests_per_month).
--
-- Hybrid actuals model (per docs/KPI App Architecture.md §1.2): these
-- RPCs compute the requested period's value live from existing sales
-- tables/views, and never write to public.kpi_monthly_values. Closed
-- months will eventually be served by reading kpi_monthly_values via
-- a separate dispatcher RPC; that dispatcher is intentionally NOT
-- introduced in this migration (smallest safe step first).
--
-- Underlying source: public.v_sales_transactions_enriched. That view
-- is already the canonical post-classification join over
-- public.sales_transactions and public.staff_members and is the same
-- view used by v_commission_calculations_core and the existing
-- payroll/commission reporting layer. Reusing it (a) keeps the
-- revenue/guest figures definitionally aligned with what the rest of
-- the app already shows, and (b) preserves the existing assistant
-- redirect attribution so a stylist's "own sales" matches what the
-- payroll views already credit them with.
--
-- Per-stylist attribution: commission_owner_candidate_id from the
-- enriched view. This is the post-redirect owner, so an assistant
-- working a senior stylist's job is correctly credited to the
-- senior stylist (matches §5 / §8 of the KPI architecture doc).
--
-- Internal-line exclusion: rows whose commission_owner_candidate_name
-- is 'internal' (case-insensitive) are excluded from revenue and
-- guests at every scope. This mirrors the existing
-- v_stylist_commission_*_access_scoped views and keeps these KPIs
-- consistent with the production "Total sales" already reported.
--
-- Customer identity for guests_per_month: WHOLE NAME is preserved on
-- public.sales_transactions.customer_name (see
-- 20260418130000_fix_apply_sales_daily_sheets_mapping.sql), and is
-- normalised on read via public.normalise_customer_name() per §6 / §7
-- of the KPI architecture doc.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Caller-context helpers (private schema, SECURITY DEFINER).
--
-- Both helpers read public.staff_member_user_access for the calling
-- auth.uid() and return a deterministic single value (or NULL if the
-- caller has no active mapping). They are STABLE so PostgREST can
-- cache them within a single statement.
--
-- Roles in the access table (locked since 20260430210000):
--   stylist, assistant, manager, admin   (+ legacy superadmin)
-- "Elevated" = manager / admin / superadmin (matches
-- private.user_has_elevated_access()).
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.kpi_caller_access_role()
  RETURNS text
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public, auth, pg_temp
AS $$
  SELECT a.access_role
  FROM public.staff_member_user_access a
  WHERE a.user_id = auth.uid()
    AND a.is_active = true
  ORDER BY
    CASE a.access_role
      WHEN 'admin'      THEN 1
      WHEN 'superadmin' THEN 1
      WHEN 'manager'    THEN 2
      WHEN 'stylist'    THEN 3
      WHEN 'assistant'  THEN 4
      ELSE 9
    END
  LIMIT 1;
$$;

ALTER FUNCTION private.kpi_caller_access_role() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.kpi_caller_access_role() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.kpi_caller_access_role() TO authenticated;
GRANT EXECUTE ON FUNCTION private.kpi_caller_access_role() TO service_role;

CREATE OR REPLACE FUNCTION private.kpi_caller_staff_member_id()
  RETURNS uuid
  LANGUAGE sql
  STABLE
  SECURITY DEFINER
  SET search_path = public, auth, pg_temp
AS $$
  SELECT a.staff_member_id
  FROM public.staff_member_user_access a
  WHERE a.user_id = auth.uid()
    AND a.is_active = true
    AND a.staff_member_id IS NOT NULL
  ORDER BY
    CASE a.access_role
      WHEN 'admin'      THEN 1
      WHEN 'superadmin' THEN 1
      WHEN 'manager'    THEN 2
      WHEN 'stylist'    THEN 3
      WHEN 'assistant'  THEN 4
      ELSE 9
    END
  LIMIT 1;
$$;

ALTER FUNCTION private.kpi_caller_staff_member_id() OWNER TO postgres;
REVOKE ALL ON FUNCTION private.kpi_caller_staff_member_id() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.kpi_caller_staff_member_id() TO authenticated;
GRANT EXECUTE ON FUNCTION private.kpi_caller_staff_member_id() TO service_role;


-- ---------------------------------------------------------------------
-- 2. Scope-resolution helper.
--
-- Given a requested scope/location/staff and the caller's role,
-- returns the (possibly resolved) effective scope or RAISES if the
-- caller is not allowed to see it. Resolution rules (per §4 / §5):
--
--   * elevated (admin/manager/superadmin):
--       - any of business / location / staff
--       - staff scope with NULL staff_id is rejected (must be explicit)
--       - location scope with NULL location_id is rejected
--   * stylist / assistant (non-elevated):
--       - ONLY staff scope, AND only their own staff_member_id
--       - if p_staff_member_id IS NULL, it is resolved to the
--         caller's own staff_member_id
--       - any other request -> 'not authorized'
--   * unauthenticated / unmapped:
--       - 'not authenticated' / 'no active access mapping'
--
-- Returns: (scope_type text, location_id uuid, staff_member_id uuid)
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.kpi_resolve_scope(
  p_scope            text,
  p_location_id      uuid,
  p_staff_member_id  uuid
)
RETURNS TABLE (
  scope_type       text,
  location_id      uuid,
  staff_member_id  uuid
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $fn$
DECLARE
  v_uid     uuid := auth.uid();
  v_role    text;
  v_self_id uuid;
  v_scope   text := COALESCE(NULLIF(btrim(p_scope), ''), 'business');
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'kpi: not authenticated' USING ERRCODE = '28000';
  END IF;

  v_role    := private.kpi_caller_access_role();
  v_self_id := private.kpi_caller_staff_member_id();

  IF v_role IS NULL THEN
    RAISE EXCEPTION 'kpi: no active access mapping for caller'
      USING ERRCODE = '42501';
  END IF;

  IF v_scope NOT IN ('business', 'location', 'staff') THEN
    RAISE EXCEPTION
      'kpi: invalid scope %, expected business|location|staff', v_scope
      USING ERRCODE = '22023';
  END IF;

  -- Non-elevated: restricted to own staff scope only.
  IF v_role IN ('stylist', 'assistant') THEN
    IF v_scope <> 'staff' THEN
      RAISE EXCEPTION
        'kpi: scope % not permitted for role %', v_scope, v_role
        USING ERRCODE = '42501';
    END IF;

    IF v_self_id IS NULL THEN
      RAISE EXCEPTION
        'kpi: caller has no staff_member mapping; cannot resolve self scope'
        USING ERRCODE = '42501';
    END IF;

    IF p_staff_member_id IS NOT NULL AND p_staff_member_id <> v_self_id THEN
      RAISE EXCEPTION
        'kpi: role % may only request its own staff scope', v_role
        USING ERRCODE = '42501';
    END IF;

    RETURN QUERY SELECT 'staff'::text, NULL::uuid, v_self_id;
    RETURN;
  END IF;

  -- Elevated: must supply the scope key for non-business scopes.
  IF v_scope = 'staff' AND p_staff_member_id IS NULL THEN
    RAISE EXCEPTION 'kpi: staff scope requires p_staff_member_id'
      USING ERRCODE = '22023';
  END IF;
  IF v_scope = 'location' AND p_location_id IS NULL THEN
    RAISE EXCEPTION 'kpi: location scope requires p_location_id'
      USING ERRCODE = '22023';
  END IF;

  IF v_scope = 'business' THEN
    RETURN QUERY SELECT 'business'::text, NULL::uuid, NULL::uuid;
  ELSIF v_scope = 'location' THEN
    RETURN QUERY SELECT 'location'::text, p_location_id, NULL::uuid;
  ELSE
    RETURN QUERY SELECT 'staff'::text, NULL::uuid, p_staff_member_id;
  END IF;
END;
$fn$;

ALTER FUNCTION private.kpi_resolve_scope(text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION private.kpi_resolve_scope(text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION private.kpi_resolve_scope(text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION private.kpi_resolve_scope(text, uuid, uuid) TO service_role;


-- ---------------------------------------------------------------------
-- 3. Embedded regression tests for public.normalise_customer_name.
--
-- These run at migration time. If any case fails the migration is
-- aborted in the transaction wrapper supabase-cli uses, so a future
-- accidental change to the function semantics cannot land silently.
-- The cases below are the exact examples called out in
-- docs/KPI App Architecture.md §7 plus the locked v1 limitation
-- (Savannagh middle-paren) noted in the function header comment.
-- ---------------------------------------------------------------------
DO $tests$
DECLARE
  cases CONSTANT jsonb := jsonb_build_array(
    -- (raw, expected, label)
    jsonb_build_array('Ashley Smythe (75)',          'ashley smythe',          'paren_with_number'),
    jsonb_build_array('Colleen Clapshaw (A)',        'colleen clapshaw',       'paren_with_letter'),
    jsonb_build_array('Zara Ellis (comp winner)',    'zara ellis',             'paren_with_words'),
    jsonb_build_array('Alice Vermunt 60',            'alice vermunt',          'trailing_number'),
    jsonb_build_array('Rachael Hausman 60 A',        'rachael hausman',        'trailing_number_then_letter'),
    jsonb_build_array('Christine Ridley C',          'christine ridley',       'trailing_letter_C'),
    jsonb_build_array('Kanika Jhamb B',              'kanika jhamb',           'trailing_letter_B'),
    jsonb_build_array('Mixed   Case   Spaces',       'mixed case spaces',      'collapse_spaces_lowercase'),
    jsonb_build_array('  Trim Me  ',                 'trim me',                'trim_outer_whitespace'),
    -- §7.2 known v1 limitation: middle-parenthesis preferred name is
    -- intentionally over-normalised; the function currently truncates
    -- at the first '('. We assert the documented (limited) output
    -- so any future relaxation has to update this case explicitly.
    jsonb_build_array('Savannagh (Mari) Primrose',   'savannagh',              'known_limitation_middle_paren'),
    -- nulls / empties round-trip to NULL (see NULLIF in fn body).
    jsonb_build_array(NULL,                          NULL,                     'null_input_returns_null'),
    jsonb_build_array('',                            NULL,                     'empty_input_returns_null'),
    jsonb_build_array('   ',                         NULL,                     'blank_input_returns_null')
  );
  c       jsonb;
  raw_in  text;
  exp_out text;
  got_out text;
  label   text;
BEGIN
  FOR c IN SELECT * FROM jsonb_array_elements(cases) LOOP
    raw_in  := c->>0;
    exp_out := c->>1;
    label   := c->>2;
    got_out := public.normalise_customer_name(raw_in);

    IF got_out IS DISTINCT FROM exp_out THEN
      RAISE EXCEPTION
        'normalise_customer_name regression: case=% raw=% expected=% got=%',
        label, raw_in, exp_out, got_out;
    END IF;
  END LOOP;
END
$tests$;


-- ---------------------------------------------------------------------
-- 4. public.get_kpi_revenue_live
--
-- Returns the live revenue (sum of price_ex_gst) for the requested
-- scope and period, MTD-clipped to today for the current open month.
--
-- Parameters:
--   p_period_start    date  default = first day of current month
--                          (any 1st-of-month accepted; the live RPC
--                           will compute against raw transactions for
--                           that month rather than reading
--                           kpi_monthly_values).
--   p_scope           text  default 'business' ('business' | 'location' | 'staff')
--   p_location_id     uuid  required for scope='location' (elevated)
--   p_staff_member_id uuid  required for scope='staff' (elevated);
--                           ignored / replaced by caller's own
--                           staff_member_id for stylist/assistant.
--
-- Returns one row.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_kpi_revenue_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'business',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code              text,
  scope_type            text,
  location_id           uuid,
  staff_member_id       uuid,
  period_start          date,
  period_end            date,
  mtd_through           date,
  is_current_open_month boolean,
  value                 numeric(18, 4),
  value_numerator       numeric(18, 4),
  value_denominator     numeric(18, 4),
  source                text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date;
  v_period_end   date;
  v_mtd_through  date;
  v_is_current   boolean;
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
  v_total        numeric(18, 4);
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_revenue_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  SELECT COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4)
    INTO v_total
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = v_period_start
    AND e.sale_date  <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND (
      v_scope = 'business'
      OR (v_scope = 'location' AND e.location_id = v_loc_id)
      OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = v_staff_id)
    );

  RETURN QUERY
  SELECT
    'revenue'::text                                                 AS kpi_code,
    v_scope                                                         AS scope_type,
    v_loc_id                                                        AS location_id,
    v_staff_id                                                      AS staff_member_id,
    v_period_start                                                  AS period_start,
    v_period_end                                                    AS period_end,
    v_mtd_through                                                   AS mtd_through,
    v_is_current                                                    AS is_current_open_month,
    v_total                                                         AS value,
    v_total                                                         AS value_numerator,
    NULL::numeric(18, 4)                                            AS value_denominator,
    'public.v_sales_transactions_enriched (price_ex_gst)'::text     AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_revenue_live(date, text, uuid, uuid) IS
'Live revenue (ex GST) KPI for the current open month (or any past month, computed live from v_sales_transactions_enriched). Stylist/assistant callers are silently restricted to their own staff scope. Does not read or write kpi_monthly_values.';


-- ---------------------------------------------------------------------
-- 5. public.get_kpi_guests_per_month_live
--
-- Returns the live distinct-normalised-guest count for the requested
-- scope and period, MTD-clipped to today for the current open month.
--
-- Identity rule: distinct
--   public.normalise_customer_name(sales_transactions.customer_name)
-- after dropping NULL/empty after normalisation. This matches §6.2
-- of the KPI architecture doc.
-- ---------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_kpi_guests_per_month_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'business',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code              text,
  scope_type            text,
  location_id           uuid,
  staff_member_id       uuid,
  period_start          date,
  period_end            date,
  mtd_through           date,
  is_current_open_month boolean,
  value                 numeric(18, 4),
  value_numerator       numeric(18, 4),
  value_denominator     numeric(18, 4),
  source                text
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_period_start date;
  v_period_end   date;
  v_mtd_through  date;
  v_is_current   boolean;
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
  v_guests       numeric(18, 4);
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_guests_per_month_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  SELECT COALESCE(
           COUNT(DISTINCT public.normalise_customer_name(e.customer_name)),
           0
         )::numeric(18, 4)
    INTO v_guests
  FROM public.v_sales_transactions_enriched e
  WHERE e.month_start = v_period_start
    AND e.sale_date  <= v_mtd_through
    AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
    AND public.normalise_customer_name(e.customer_name) IS NOT NULL
    AND (
      v_scope = 'business'
      OR (v_scope = 'location' AND e.location_id = v_loc_id)
      OR (v_scope = 'staff'    AND e.commission_owner_candidate_id = v_staff_id)
    );

  RETURN QUERY
  SELECT
    'guests_per_month'::text                                                     AS kpi_code,
    v_scope                                                                      AS scope_type,
    v_loc_id                                                                     AS location_id,
    v_staff_id                                                                   AS staff_member_id,
    v_period_start                                                               AS period_start,
    v_period_end                                                                 AS period_end,
    v_mtd_through                                                                AS mtd_through,
    v_is_current                                                                 AS is_current_open_month,
    v_guests                                                                     AS value,
    v_guests                                                                     AS value_numerator,
    NULL::numeric(18, 4)                                                         AS value_denominator,
    'distinct normalise_customer_name(customer_name) over v_sales_transactions_enriched'::text AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_guests_per_month_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.get_kpi_guests_per_month_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_guests_per_month_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_guests_per_month_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_guests_per_month_live(date, text, uuid, uuid) IS
'Live distinct-guest count KPI for the current open month (or any past month). Identity = public.normalise_customer_name(sales_transactions.customer_name). Stylist/assistant callers are silently restricted to their own staff scope. Does not read or write kpi_monthly_values.';
