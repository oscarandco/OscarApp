


SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "private";


ALTER SCHEMA "private" OWNER TO "postgres";


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE OR REPLACE FUNCTION "private"."kpi_caller_access_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
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


ALTER FUNCTION "private"."kpi_caller_access_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."kpi_caller_staff_member_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
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


ALTER FUNCTION "private"."kpi_caller_staff_member_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."kpi_resolve_scope"("p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") RETURNS TABLE("scope_type" "text", "location_id" "uuid", "staff_member_id" "uuid")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "private"."kpi_resolve_scope"("p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."quote_sections_block_delete_if_used"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
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


ALTER FUNCTION "private"."quote_sections_block_delete_if_used"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."quote_service_options_block_delete_if_used"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
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


ALTER FUNCTION "private"."quote_service_options_block_delete_if_used"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."quote_service_options_validate_row"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_service_id uuid;
BEGIN
  v_service_id := COALESCE(NEW.service_id, OLD.service_id);
  PERFORM private.validate_quote_service_option_pricing(v_service_id);
  PERFORM private.validate_quote_service_has_active_option(v_service_id);
  RETURN NULL;
END;
$$;


ALTER FUNCTION "private"."quote_service_options_validate_row"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."quote_service_role_prices_validate_row"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_service_id uuid;
BEGIN
  v_service_id := COALESCE(NEW.service_id, OLD.service_id);
  PERFORM private.validate_quote_service_role_prices(v_service_id);
  RETURN NULL;
END;
$$;


ALTER FUNCTION "private"."quote_service_role_prices_validate_row"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."quote_services_block_delete_if_used"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
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


ALTER FUNCTION "private"."quote_services_block_delete_if_used"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."quote_services_validate_row"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  PERFORM private.validate_quote_service_role_prices(NEW.id);
  PERFORM private.validate_quote_service_option_pricing(NEW.id);
  PERFORM private.validate_quote_service_has_active_option(NEW.id);
  RETURN NULL;
END;
$$;


ALTER FUNCTION "private"."quote_services_validate_row"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."run_sales_daily_sheets_merge_if_installed"("p_batch_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF to_regprocedure('public.apply_sales_daily_sheets_to_payroll(uuid)') IS NOT NULL THEN
    PERFORM public.apply_sales_daily_sheets_to_payroll(p_batch_id);
  END IF;
END;
$$;


ALTER FUNCTION "private"."run_sales_daily_sheets_merge_if_installed"("p_batch_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."user_can_manage_access_mappings"() RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
    AS $$
    SELECT EXISTS (
        SELECT 1 
        FROM public.staff_member_user_access 
        WHERE user_id = auth.uid()
          AND is_active = true
          AND access_role IN ('admin', 'superadmin')
    );
$$;


ALTER FUNCTION "private"."user_can_manage_access_mappings"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."user_has_elevated_access"() RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
    AS $$
    SELECT EXISTS (
        SELECT 1 
        FROM public.staff_member_user_access 
        WHERE user_id = auth.uid()
          AND is_active = true
          AND access_role IN ('admin', 'superadmin', 'manager')
    );
$$;


ALTER FUNCTION "private"."user_has_elevated_access"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."validate_quote_service_has_active_option"("p_service_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_input_type text;
  v_pricing_type text;
  v_active_count integer;
BEGIN
  SELECT input_type, pricing_type
    INTO v_input_type, v_pricing_type
    FROM public.quote_services
    WHERE id = p_service_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_input_type IN ('option_radio', 'dropdown')
     OR v_pricing_type = 'option_price' THEN

    SELECT count(*) INTO v_active_count
      FROM public.quote_service_options
      WHERE service_id = p_service_id AND active = true;

    IF v_active_count < 1 THEN
      RAISE EXCEPTION
        'option-based service requires at least one active option (service=%, input_type=%, pricing_type=%)',
        p_service_id, v_input_type, v_pricing_type
        USING ERRCODE = '23514';
    END IF;
  END IF;
END;
$$;


ALTER FUNCTION "private"."validate_quote_service_has_active_option"("p_service_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."validate_quote_service_option_pricing"("p_service_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_pricing_type text;
  v_bad_count integer;
BEGIN
  SELECT pricing_type
    INTO v_pricing_type
    FROM public.quote_services
    WHERE id = p_service_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_pricing_type = 'option_price' THEN
    SELECT count(*) INTO v_bad_count
      FROM public.quote_service_options
      WHERE service_id = p_service_id AND price IS NULL;

    IF v_bad_count > 0 THEN
      RAISE EXCEPTION
        'quote_service_options.price must be set when parent service.pricing_type = option_price (service=%, null_price_rows=%)',
        p_service_id, v_bad_count
        USING ERRCODE = '23514';
    END IF;
  ELSE
    SELECT count(*) INTO v_bad_count
      FROM public.quote_service_options
      WHERE service_id = p_service_id AND price IS NOT NULL;

    IF v_bad_count > 0 THEN
      RAISE EXCEPTION
        'quote_service_options.price must be null when parent service.pricing_type <> option_price (service=%, pricing_type=%, non_null_price_rows=%)',
        p_service_id, v_pricing_type, v_bad_count
        USING ERRCODE = '23514';
    END IF;
  END IF;
END;
$$;


ALTER FUNCTION "private"."validate_quote_service_option_pricing"("p_service_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "private"."validate_quote_service_role_prices"("p_service_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_pricing_type text;
  v_visible_roles text[];
  v_extra_roles text[];
  v_missing_roles text[];
  v_row_count integer;
BEGIN
  SELECT pricing_type, visible_roles
    INTO v_pricing_type, v_visible_roles
    FROM public.quote_services
    WHERE id = p_service_id;

  -- Service no longer exists (e.g. cascade delete). Nothing to validate.
  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_pricing_type = 'role_price' THEN
    -- No role_price rows for roles outside visible_roles.
    SELECT array_agg(rp.role ORDER BY rp.role)
      INTO v_extra_roles
      FROM public.quote_service_role_prices rp
      WHERE rp.service_id = p_service_id
        AND NOT (rp.role = ANY (v_visible_roles));

    IF v_extra_roles IS NOT NULL THEN
      RAISE EXCEPTION
        'quote_service_role_prices has rows for roles not in visible_roles (service=%, extra_roles=%)',
        p_service_id, v_extra_roles
        USING ERRCODE = '23514';
    END IF;

    -- Every visible role must have a row.
    SELECT array_agg(r ORDER BY r)
      INTO v_missing_roles
      FROM unnest(v_visible_roles) AS r
      WHERE NOT EXISTS (
        SELECT 1 FROM public.quote_service_role_prices rp
        WHERE rp.service_id = p_service_id
          AND rp.role = r
      );

    IF v_missing_roles IS NOT NULL THEN
      RAISE EXCEPTION
        'quote_service_role_prices missing rows for visible roles (service=%, missing_roles=%)',
        p_service_id, v_missing_roles
        USING ERRCODE = '23514';
    END IF;
  ELSE
    -- Non role_price services must have zero role-price rows.
    SELECT count(*) INTO v_row_count
      FROM public.quote_service_role_prices
      WHERE service_id = p_service_id;

    IF v_row_count > 0 THEN
      RAISE EXCEPTION
        'quote_service_role_prices has rows for a non-role_price service (service=%, pricing_type=%, row_count=%)',
        p_service_id, v_pricing_type, v_row_count
        USING ERRCODE = '23514';
    END IF;
  END IF;
END;
$$;


ALTER FUNCTION "private"."validate_quote_service_role_prices"("p_service_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_delete_remuneration_plan_if_unused"("p_plan_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_plan_name text;
  v_count bigint;
BEGIN
  IF NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  SELECT rp.plan_name INTO v_plan_name
  FROM public.remuneration_plans rp
  WHERE rp.id = p_plan_id;

  IF v_plan_name IS NULL THEN
    RAISE EXCEPTION 'remuneration plan not found';
  END IF;

  SELECT count(*)::bigint INTO v_count
  FROM public.staff_members sm
  WHERE sm.remuneration_plan IS NOT NULL
    AND btrim(sm.remuneration_plan) <> ''
    AND lower(trim(sm.remuneration_plan)) = lower(trim(v_plan_name));

  IF v_count > 0 THEN
    RAISE EXCEPTION
      'Cannot delete this plan: % staff still assigned. Reassign them in Staff Configuration first.',
      v_count;
  END IF;

  DELETE FROM public.remuneration_plans WHERE id = p_plan_id;
END;
$$;


ALTER FUNCTION "public"."admin_delete_remuneration_plan_if_unused"("p_plan_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_remuneration_staff_counts"() RETURNS TABLE("plan_key" "text", "staff_count" bigint)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  SELECT lower(trim(sm.remuneration_plan)) AS plan_key,
         count(*)::bigint AS staff_count
  FROM public.staff_members sm
  WHERE sm.remuneration_plan IS NOT NULL
    AND btrim(sm.remuneration_plan) <> ''
    AND (SELECT private.user_has_elevated_access())
  GROUP BY lower(trim(sm.remuneration_plan));
$$;


ALTER FUNCTION "public"."admin_remuneration_staff_counts"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_staff_for_remuneration_plan"("p_plan_name" "text") RETURNS TABLE("staff_member_id" "uuid", "display_name" "text", "full_name" "text", "is_active" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  SELECT s.id,
         s.display_name,
         s.full_name,
         s.is_active
  FROM public.staff_members s
  WHERE (SELECT private.user_has_elevated_access())
    AND p_plan_name IS NOT NULL
    AND btrim(p_plan_name) <> ''
    AND s.remuneration_plan IS NOT NULL
    AND lower(trim(s.remuneration_plan)) = lower(trim(p_plan_name))
  ORDER BY COALESCE(s.display_name, s.full_name, '');
$$;


ALTER FUNCTION "public"."admin_staff_for_remuneration_plan"("p_plan_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_sales_daily_sheets_to_payroll"("p_batch_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private', 'pg_temp'
    AS $_$
DECLARE
  v_sheet public.sales_daily_sheets_import_batches%ROWTYPE;
  v_payroll_id uuid;
  v_staged integer;
  v_loaded integer;
  v_source_file text;
  v_location_id uuid;
  t_mark timestamptz;
  t_apply_start timestamptz;
BEGIN
  PERFORM set_config('statement_timeout', '0', true);
  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=statement_timeout_disabled_tx_local',
    p_batch_id;

  SELECT *
  INTO v_sheet
  FROM public.sales_daily_sheets_import_batches b
  WHERE b.id = p_batch_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'sales daily sheets batch not found: %', p_batch_id;
  END IF;

  IF auth.uid() IS NOT NULL THEN
    IF NOT (
      (SELECT private.user_has_elevated_access())
      OR v_sheet.created_by = auth.uid()
    ) THEN
      RAISE EXCEPTION 'not authorized';
    END IF;
  END IF;

  SELECT count(*)::integer
  INTO v_staged
  FROM public.sales_daily_sheets_staged_rows r
  WHERE r.batch_id = p_batch_id;

  IF v_staged = 0 THEN
    RAISE EXCEPTION 'no staged rows for batch %', p_batch_id;
  END IF;

  t_apply_start := clock_timestamp();

  v_payroll_id := v_sheet.payroll_import_batch_id;

  IF v_payroll_id IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.sales_import_batches b WHERE b.id = v_payroll_id
  ) THEN
    v_payroll_id := NULL;
    UPDATE public.sales_daily_sheets_import_batches b
    SET payroll_import_batch_id = NULL
    WHERE b.id = p_batch_id;
  END IF;

  v_source_file := trim(regexp_replace(trim(coalesce(v_sheet.storage_path, '')), '^.*/', ''));
  v_source_file := nullif(v_source_file, '');
  IF v_source_file IS NULL THEN
    v_source_file := trim(coalesce(v_sheet.storage_path, ''));
  END IF;

  v_location_id := v_sheet.selected_location_id;

  IF v_location_id IS NULL THEN
    v_location_id := (
      SELECT r.location_id
      FROM public.sales_daily_sheets_staged_rows r
      WHERE r.batch_id = p_batch_id
        AND r.location_id IS NOT NULL
      LIMIT 1
    );
  END IF;

  IF v_location_id IS NULL THEN
    v_location_id := public.get_location_id_from_filename(v_source_file);
  END IF;


  IF v_location_id IS NULL AND v_payroll_id IS NOT NULL THEN
    SELECT b.location_id INTO v_location_id
    FROM public.sales_import_batches b
    WHERE b.id = v_payroll_id;
  END IF;

  t_mark := clock_timestamp();
  IF v_location_id IS NOT NULL THEN
    DELETE FROM public.sales_transactions st
    USING public.sales_import_batches b
    WHERE st.import_batch_id = b.id
      AND b.source_name = 'SalesDailySheets'
      AND b.location_id = v_location_id
      AND (v_payroll_id IS NULL OR b.id <> v_payroll_id);

    DELETE FROM public.raw_sales_import_rows rr
    USING public.sales_import_batches b
    WHERE rr.import_batch_id = b.id
      AND b.source_name = 'SalesDailySheets'
      AND b.location_id = v_location_id
      AND (v_payroll_id IS NULL OR b.id <> v_payroll_id);

    DELETE FROM public.sales_import_batches b
    WHERE b.source_name = 'SalesDailySheets'
      AND b.location_id = v_location_id
      AND (v_payroll_id IS NULL OR b.id <> v_payroll_id);
  END IF;

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=location_scoped_deletes ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_mark)) * 1000)::bigint);

  IF v_payroll_id IS NULL THEN
    IF v_location_id IS NULL THEN
      RAISE EXCEPTION
        'cannot resolve location_id for sales daily sheets batch % (set selected_location_id, staged location_id, or use a storage filename that maps via get_location_id_from_filename)',
        p_batch_id;
    END IF;

    INSERT INTO public.sales_import_batches (
      source_name,
      source_file_name,
      location_id,
      imported_by_user_id,
      status,
      notes
    )
    VALUES (
      'SalesDailySheets',
      v_source_file,
      v_location_id,
      v_sheet.created_by,
      'pending',
      format('Sales Daily Sheets staged import; sheet batch %s', p_batch_id)
    )
    RETURNING id INTO v_payroll_id;

    UPDATE public.sales_daily_sheets_import_batches b
    SET payroll_import_batch_id = v_payroll_id
    WHERE b.id = p_batch_id;
  END IF;

  t_mark := clock_timestamp();
  DELETE FROM public.sales_transactions st
  WHERE st.import_batch_id = v_payroll_id;

  DELETE FROM public.raw_sales_import_rows rr
  WHERE rr.import_batch_id = v_payroll_id;

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=payroll_batch_preclear ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_mark)) * 1000)::bigint);

  t_mark := clock_timestamp();
  INSERT INTO public.raw_sales_import_rows (
    import_batch_id,
    category,
    first_name,
    qty,
    prod_total,
    prod_id,
    sale_datetime,
    source_document_number,
    description,
    whole_name,
    product_type,
    parent_prod_type,
    prod_cat,
    staff_work_name,
    raw_location,
    row_num,
    raw_payload
  )
  SELECT
    v_payroll_id,

    CASE
      WHEN nullif(btrim(coalesce(r.extras->>'category', r.extras->>'CATEGORY')), '') IS NULL THEN NULL
      WHEN regexp_replace(btrim(coalesce(r.extras->>'category', r.extras->>'CATEGORY')), '\.0+$', '') ~ '^-?[0-9]+$'
        THEN regexp_replace(btrim(coalesce(r.extras->>'category', r.extras->>'CATEGORY')), '\.0+$', '')::integer
      ELSE NULL
    END,

    CASE
      WHEN nullif(btrim(r.derived_staff_paid_display_name), '') IS NOT NULL THEN
        split_part(btrim(r.derived_staff_paid_display_name), ' ', 1)
      WHEN nullif(btrim(r.extras->>'FIRST_NAME'), '') IS NOT NULL THEN
        btrim(r.extras->>'FIRST_NAME')
      WHEN nullif(btrim(r.extras->>'NAME'), '') IS NOT NULL THEN
        split_part(btrim(r.extras->>'NAME'), ' ', 1)
      ELSE NULL
    END,

    CASE
      WHEN r.quantity IS NOT NULL
        AND r.quantity::text ~ '^-?[0-9]+(\.[0-9]+)?$' THEN
        round(r.quantity)::integer
      WHEN nullif(
        replace(btrim(coalesce(r.extras->>'QTY', r.extras->>'qty')), ',', ''),
        ''
      ) IS NOT NULL
        AND regexp_replace(
          btrim(coalesce(r.extras->>'QTY', r.extras->>'qty')),
          '\.0+$',
          ''
        ) ~ '^-?[0-9]+$' THEN
        regexp_replace(
          btrim(coalesce(r.extras->>'QTY', r.extras->>'qty')),
          '\.0+$',
          ''
        )::integer
      ELSE NULL
    END,

    CASE
      WHEN r.price_ex_gst IS NOT NULL THEN
        round(r.price_ex_gst::numeric, 2)
      WHEN nullif(
        replace(
          btrim(coalesce(r.extras->>'PROD_TOTAL', r.extras->>'prod_total')),
          ',',
          ''
        ),
        ''
      ) IS NOT NULL
        AND replace(
          btrim(coalesce(r.extras->>'PROD_TOTAL', r.extras->>'prod_total')),
          ',',
          ''
        ) ~ '^-?\d+(\.\d+)?$' THEN
        replace(
          btrim(coalesce(r.extras->>'PROD_TOTAL', r.extras->>'prod_total')),
          ',',
          ''
        )::numeric(12, 2)
      ELSE NULL
    END,

    nullif(
      btrim(coalesce(r.extras->>'prod_id', r.extras->>'PROD_ID')),
      ''
    ),

    COALESCE(
      CASE
        WHEN nullif(btrim(coalesce(r.sale_date, r.extras->>'DATE')), '') IS NULL THEN NULL
        WHEN btrim(coalesce(r.sale_date, r.extras->>'DATE')) ~ '^\d{4}-\d{2}-\d{2}' THEN
          (
            left(btrim(coalesce(r.sale_date, r.extras->>'DATE')), 10)::date + time '12:00'
          ) AT TIME ZONE 'Pacific/Auckland'
        ELSE
          btrim(coalesce(r.sale_date, r.extras->>'DATE'))::timestamptz
      END,
      (
        coalesce(r.pay_week_start, r.pay_date, CURRENT_DATE)::timestamp + interval '12 hours'
      ) AT TIME ZONE 'Pacific/Auckland'
    ),

    nullif(
      btrim(
        coalesce(
          r.invoice,
          r.extras->>'SOURCE_DOCUMENT_NUMBER',
          r.extras->>'source_document_number'
        )
      ),
      ''
    ),

    coalesce(
      nullif(btrim(r.product_service_name), ''),
      nullif(btrim(r.extras->>'DESCRIPTION'), ''),
      '(daily sheet row)'
    ),

    nullif(
      btrim(
        coalesce(
          r.customer_name,
          r.extras->>'WHOLE_NAME',
          r.extras->>'whole_name'
        )
      ),
      ''
    ),

    coalesce(
      nullif(btrim(r.extras->>'product_type'), ''),
      nullif(btrim(r.extras->>'PRODUCT_TYPE'), ''),
      'Service'
    ),

    nullif(
      btrim(
        coalesce(
          r.extras->>'parent_prod_type',
          r.extras->>'PARENT_PROD_TYPE'
        )
      ),
      ''
    ),

    nullif(
      btrim(coalesce(r.extras->>'prod_cat', r.extras->>'PROD_CAT')),
      ''
    ),

    nullif(
      btrim(
        coalesce(
          r.derived_staff_paid_display_name,
          r.extras->>'NAME'
        )
      ),
      ''
    ),

    v_payroll_id::text,
    r.line_number,

    r.extras
      || jsonb_build_object(
        'sales_daily_sheets_staged_row_id', r.id,
        'sheet_batch_id', p_batch_id,
        'storage_path', v_sheet.storage_path,
        'sale_date_raw', r.sale_date,
        'pay_week_start', r.pay_week_start,
        'pay_week_end', r.pay_week_end,
        'pay_date', r.pay_date,
        'payroll_status', r.payroll_status,
        'stylist_visible_note', r.stylist_visible_note,
        'actual_commission_amount', r.actual_commission_amount,
        'assistant_commission_amount', r.assistant_commission_amount,
        'derived_staff_paid_display_name', r.derived_staff_paid_display_name,
        'staged_invoice', r.invoice,
        'staged_product_service_name', r.product_service_name,
        'staged_customer_name', r.customer_name,
        'staged_quantity', r.quantity,
        'staged_price_ex_gst', r.price_ex_gst,
        'selected_location_id', v_sheet.selected_location_id
      )
  FROM public.sales_daily_sheets_staged_rows r
  WHERE r.batch_id = p_batch_id
  ORDER BY r.line_number;

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=raw_sales_import_rows_insert ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_mark)) * 1000)::bigint);

  t_mark := clock_timestamp();
  v_loaded := public.load_raw_sales_rows_to_transactions(v_payroll_id);

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=load_raw_sales_rows_to_transactions ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_mark)) * 1000)::bigint);

  t_mark := clock_timestamp();
  UPDATE public.sales_import_batches b
  SET
    status = 'processed',
    row_count = v_loaded,
    imported_by_user_id = coalesce(b.imported_by_user_id, auth.uid()),
    updated_at = now()
  WHERE b.id = v_payroll_id;

  UPDATE public.sales_daily_sheets_import_batches b
  SET rows_loaded = v_loaded
  WHERE b.id = p_batch_id;

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=final_batch_updates ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_mark)) * 1000)::bigint);

  RAISE LOG 'sds_timing apply_sales_daily_sheets_to_payroll batch_id=% step=apply_sales_daily_sheets_to_payroll_total ms=%',
    p_batch_id,
    (round(extract(epoch from (clock_timestamp() - t_apply_start)) * 1000)::bigint);
END;

$_$;


ALTER FUNCTION "public"."apply_sales_daily_sheets_to_payroll"("p_batch_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."apply_sales_daily_sheets_to_payroll"("p_batch_id" "uuid") IS 'Maps staged rows to raw_sales_import_rows and load_raw_sales_rows_to_transactions. Before apply, deletes prior SalesDailySheets payroll rows for the same location only (other locations untouched).';



CREATE OR REPLACE FUNCTION "public"."bulk_stage_sales_rows"("p_rows" "jsonb") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare
  v_count integer;
begin
  insert into public.stg_salesdailysheets (
    "CATEGORY",
    "FIRST_NAME",
    "QTY",
    "PROD_TOTAL",
    "PROD_ID",
    "DATE",
    "SOURCE_DOCUMENT_NUMBER",
    "DESCRIPTION",
    "WHOLE_NAME",
    "PRODUCT_TYPE",
    "PARENT_PROD_TYPE",
    "PROD_CAT",
    "NAME"
  )
  select
    nullif(btrim(elem->>0), ''),
    nullif(btrim(elem->>1), ''),
    nullif(btrim(elem->>2), ''),
    nullif(btrim(elem->>3), ''),
    nullif(btrim(elem->>4), ''),
    nullif(btrim(elem->>5), ''),
    nullif(btrim(elem->>6), ''),
    nullif(btrim(elem->>7), ''),
    nullif(btrim(elem->>8), ''),
    nullif(btrim(elem->>9), ''),
    nullif(btrim(elem->>10), ''),
    nullif(btrim(elem->>11), ''),
    nullif(btrim(elem->>12), '')
  from jsonb_array_elements(p_rows) as t(elem);

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."bulk_stage_sales_rows"("p_rows" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."caller_can_manage_access_mappings"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
    AS $$
  SELECT private.user_can_manage_access_mappings();
$$;


ALTER FUNCTION "public"."caller_can_manage_access_mappings"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_stg_salesdailysheets"() RETURNS "void"
    LANGUAGE "sql"
    AS $$
  truncate table public.stg_salesdailysheets;
$$;


ALTER FUNCTION "public"."clear_stg_salesdailysheets"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."staff_member_user_access" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "staff_member_id" "uuid",
    "access_role" "text" DEFAULT 'stylist'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_member_user_access_role_check" CHECK (("access_role" = ANY (ARRAY['stylist'::"text", 'assistant'::"text", 'manager'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."staff_member_user_access" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_access_mapping"("p_user_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean DEFAULT true) RETURNS "public"."staff_member_user_access"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_row public.staff_member_user_access;
begin
  if not private.user_can_manage_access_mappings() then
    raise exception 'Access denied';
  end if;

  if exists (
    select 1
    from public.staff_member_user_access m
    where m.user_id = p_user_id
  ) then
    raise exception 'A mapping already exists for this user';
  end if;

  insert into public.staff_member_user_access (
    user_id,
    staff_member_id,
    access_role,
    is_active
  )
  values (
    p_user_id,
    p_staff_member_id,
    lower(trim(p_access_role)),
    p_is_active
  )
  returning *
  into v_row;

  return v_row;
end;
$$;


ALTER FUNCTION "public"."create_access_mapping"("p_user_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_sales_import_batch"("p_source_file_name" "text", "p_source_name" "text" DEFAULT 'SalesDailySheets'::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_batch_id uuid;
  v_location_id uuid;
begin
  v_location_id := public.get_location_id_from_filename(p_source_file_name);

  insert into public.sales_import_batches (
    source_name,
    source_file_name,
    location_id,
    status,
    notes
  )
  values (
    p_source_name,
    p_source_file_name,
    v_location_id,
    'pending',
    p_notes
  )
  returning id into v_batch_id;

  return v_batch_id;
end;
$$;


ALTER FUNCTION "public"."create_sales_import_batch"("p_source_file_name" "text", "p_source_name" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_all_sales_daily_sheets_import_data"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'private', 'pg_temp'
    AS $$
DECLARE
  n_tx bigint;
  n_raw bigint;
  n_batch bigint;
  n_staged bigint;
  n_sheet bigint;
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  PERFORM set_config('statement_timeout', '0', true);

  DELETE FROM public.sales_transactions st
  USING public.sales_import_batches b
  WHERE st.import_batch_id = b.id
    AND b.source_name = 'SalesDailySheets';
  GET DIAGNOSTICS n_tx = ROW_COUNT;

  DELETE FROM public.raw_sales_import_rows rr
  USING public.sales_import_batches b
  WHERE rr.import_batch_id = b.id
    AND b.source_name = 'SalesDailySheets';
  GET DIAGNOSTICS n_raw = ROW_COUNT;

  DELETE FROM public.sales_import_batches b
  WHERE b.source_name = 'SalesDailySheets';
  GET DIAGNOSTICS n_batch = ROW_COUNT;

  SELECT count(*)::bigint INTO n_staged FROM public.sales_daily_sheets_staged_rows;
  TRUNCATE TABLE public.sales_daily_sheets_staged_rows;

  SELECT count(*)::bigint INTO n_sheet FROM public.sales_daily_sheets_import_batches;
  TRUNCATE TABLE public.sales_daily_sheets_import_batches;

  RETURN jsonb_build_object(
    'sales_transactions_deleted', n_tx,
    'raw_sales_import_rows_deleted', n_raw,
    'sales_import_batches_deleted', n_batch,
    'sales_daily_sheets_staged_rows_deleted', n_staged,
    'sales_daily_sheets_import_batches_deleted', n_sheet
  );
END;
$$;


ALTER FUNCTION "public"."delete_all_sales_daily_sheets_import_data"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."delete_all_sales_daily_sheets_import_data"() IS 'Destructive reset: removes all Sales Daily Sheets import data (elevated users only). Idempotent. Uses statement_timeout=0 and TRUNCATE for SDS-only tables.';



CREATE OR REPLACE FUNCTION "public"."delete_quote_section"("p_section_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."delete_quote_section"("p_section_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_sales_daily_sheets_staged_rows_for_batch"("p_batch_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  PERFORM set_config('statement_timeout', '0', true);

  DELETE FROM public.sales_daily_sheets_staged_rows
  WHERE batch_id = p_batch_id;
END;
$$;


ALTER FUNCTION "public"."delete_sales_daily_sheets_staged_rows_for_batch"("p_batch_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."delete_sales_daily_sheets_staged_rows_for_batch"("p_batch_id" "uuid") IS 'Used by Edge sales-daily-sheets-import: clears staged rows for one batch with statement_timeout disabled.';



CREATE OR REPLACE FUNCTION "public"."delete_saved_quote"("p_saved_quote_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."delete_saved_quote"("p_saved_quote_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_is_admin_or_manager"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.staff_member_user_access a
    where a.user_id = auth.uid()
      and a.is_active = true
      and a.access_role in ('admin', 'manager')
  )
$$;


ALTER FUNCTION "public"."fn_is_admin_or_manager"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_my_access_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select a.access_role
  from public.staff_member_user_access a
  where a.user_id = auth.uid()
    and a.is_active = true
  order by a.created_at desc
  limit 1
$$;


ALTER FUNCTION "public"."fn_my_access_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_my_staff_member_id"() RETURNS "uuid"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select a.staff_member_id
  from public.staff_member_user_access a
  where a.user_id = auth.uid()
    and a.is_active = true
  order by a.created_at desc
  limit 1
$$;


ALTER FUNCTION "public"."fn_my_staff_member_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_active_quote_config"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_active_quote_config"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_active_quote_config"() IS 'Read-only stylist-facing entry point. Returns a JSON tree of active quote settings + sections + services + options + role prices. Requires auth.uid() to be non-null; bypasses RLS via SECURITY DEFINER so stylists do not need direct table read access.';



CREATE OR REPLACE FUNCTION "public"."get_admin_access_mappings"() RETURNS TABLE("mapping_id" "uuid", "user_id" "uuid", "email" "text", "staff_member_id" "uuid", "staff_display_name" "text", "staff_full_name" "text", "staff_name" "text", "access_role" "text", "is_active" boolean, "created_at" timestamp with time zone, "updated_at" timestamp with time zone, "last_sign_in_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
    AS $$
  SELECT
    sma.id AS mapping_id,
    sma.user_id,
    COALESCE(au.email::text, '') AS email,
    sma.staff_member_id,
    NULLIF(trim(COALESCE(sm.display_name::text, '')), '') AS staff_display_name,
    NULLIF(trim(COALESCE(sm.full_name::text, '')), '') AS staff_full_name,
    COALESCE(
      NULLIF(trim(COALESCE(sm.display_name::text, '')), ''),
      NULLIF(trim(COALESCE(sm.full_name::text, '')), '')
    ) AS staff_name,
    sma.access_role,
    sma.is_active,
    sma.created_at,
    sma.updated_at,
    au.last_sign_in_at
  FROM public.staff_member_user_access sma
  LEFT JOIN auth.users au ON au.id = sma.user_id
  LEFT JOIN public.staff_members sm ON sm.id = sma.staff_member_id
  WHERE private.user_has_elevated_access()
  ORDER BY sma.created_at DESC;
$$;


ALTER FUNCTION "public"."get_admin_access_mappings"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."locations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "locations_code_not_blank" CHECK (("btrim"("code") <> ''::"text")),
    CONSTRAINT "locations_name_not_blank" CHECK (("btrim"("name") <> ''::"text"))
);


ALTER TABLE "public"."locations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_master" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "product_description" "text" NOT NULL,
    "system_type" "text",
    "product_type" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "product_master_description_not_blank" CHECK (("btrim"("product_description") <> ''::"text"))
);


ALTER TABLE "public"."product_master" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."remuneration_plan_rates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "remuneration_plan_id" "uuid" NOT NULL,
    "commission_category" "text" NOT NULL,
    "rate" numeric(8,6) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "remuneration_plan_rates_category_valid" CHECK (("commission_category" = ANY (ARRAY['retail_product'::"text", 'professional_product'::"text", 'service'::"text", 'toner_with_other_service'::"text", 'extensions_product'::"text", 'extensions_service'::"text"]))),
    CONSTRAINT "remuneration_plan_rates_rate_valid" CHECK ((("rate" >= (0)::numeric) AND ("rate" <= (1)::numeric)))
);


ALTER TABLE "public"."remuneration_plan_rates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."remuneration_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "plan_name" "text" NOT NULL,
    "can_use_assistants" boolean,
    "conditions_text" "text",
    "staff_on_this_plan_text" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "remuneration_plans_name_not_blank" CHECK (("btrim"("plan_name") <> ''::"text"))
);


ALTER TABLE "public"."remuneration_plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sales_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "import_batch_id" "uuid" NOT NULL,
    "raw_row_id" "uuid",
    "location_id" "uuid" NOT NULL,
    "invoice" "text",
    "customer_name" "text",
    "sale_datetime" timestamp with time zone NOT NULL,
    "sale_date" "date" NOT NULL,
    "day_name" "text",
    "month_start" "date",
    "month_num" integer,
    "product_service_name" "text" NOT NULL,
    "product_master_id" "uuid",
    "raw_product_type" "text",
    "product_type_actual" "text",
    "product_type_short" "text",
    "commission_product_service" "text",
    "quantity" integer,
    "price_ex_gst" numeric,
    "price_incl_gst" numeric,
    "price_gst_component" numeric,
    "staff_commission_name" "text",
    "staff_work_name" "text",
    "staff_paid_name" "text",
    "staff_commission_id" "uuid",
    "staff_work_id" "uuid",
    "staff_paid_id" "uuid",
    "staff_commission_type" "text",
    "staff_work_type" "text",
    "staff_paid_type" "text",
    "assistant_usage_alert" "text",
    "staff_work_is_staff_paid" "text",
    "invoice_header" "text",
    "product_header" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sales_transactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."staff_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "full_name" "text" NOT NULL,
    "display_name" "text",
    "primary_role" "text",
    "remuneration_plan" "text",
    "employment_type" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "first_seen_sale_date" "date",
    "last_seen_sale_date" "date",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "secondary_roles" "text",
    "fte" numeric(5,4),
    "employment_start_date" "date",
    "employment_end_date" "date",
    "contractor_company_name" "text",
    "contractor_gst_registered" boolean,
    "contractor_ird_number" "text",
    "contractor_street_address" "text",
    "contractor_suburb" "text",
    "contractor_city_postcode" "text"
);


ALTER TABLE "public"."staff_members" OWNER TO "postgres";


COMMENT ON COLUMN "public"."staff_members"."secondary_roles" IS 'Optional; comma-separated or free text matching org conventions.';



COMMENT ON COLUMN "public"."staff_members"."fte" IS 'Full-time equivalent (0–1 typical).';



COMMENT ON COLUMN "public"."staff_members"."employment_start_date" IS 'Employment start (optional).';



COMMENT ON COLUMN "public"."staff_members"."employment_end_date" IS 'Employment end (optional).';



COMMENT ON COLUMN "public"."staff_members"."contractor_company_name" IS 'Contractor company (when employment_type is Contractor).';



COMMENT ON COLUMN "public"."staff_members"."contractor_gst_registered" IS 'GST registration flag for contractor.';



COMMENT ON COLUMN "public"."staff_members"."contractor_ird_number" IS 'IRD number for contractor.';



COMMENT ON COLUMN "public"."staff_members"."contractor_street_address" IS 'Contractor street address.';



COMMENT ON COLUMN "public"."staff_members"."contractor_suburb" IS 'Contractor suburb.';



COMMENT ON COLUMN "public"."staff_members"."contractor_city_postcode" IS 'Contractor city and postcode (single field).';



CREATE OR REPLACE VIEW "public"."v_sales_transactions_powerbi_parity" AS
 WITH "base" AS (
         SELECT "st"."id",
            "st"."import_batch_id",
            "st"."raw_row_id",
            "st"."location_id",
            "st"."invoice",
            "st"."customer_name",
            "st"."sale_datetime",
            "st"."sale_date",
            "st"."day_name",
            "st"."month_start",
            "st"."month_num",
            "st"."product_service_name",
            "st"."product_master_id",
            "st"."raw_product_type",
            "st"."product_type_actual" AS "existing_product_type_actual",
            "st"."product_type_short" AS "existing_product_type_short",
            "st"."commission_product_service" AS "existing_commission_product_service",
            "st"."quantity",
            "st"."price_ex_gst",
            "st"."price_incl_gst",
            "st"."price_gst_component",
            "st"."staff_commission_name",
            "st"."staff_work_name",
            "st"."staff_paid_name" AS "existing_staff_paid_name",
            "st"."staff_commission_id",
            "st"."staff_work_id",
            "st"."staff_paid_id",
            "st"."staff_commission_type",
            "st"."staff_work_type",
            "st"."staff_paid_type",
            "st"."assistant_usage_alert" AS "existing_assistant_usage_alert",
            "st"."staff_work_is_staff_paid",
            "st"."invoice_header",
            "st"."product_header",
            "st"."created_at",
            "st"."updated_at",
            "pm"."product_description" AS "master_product_description",
            "pm"."product_type" AS "master_product_type",
            "sc"."display_name" AS "commission_display_name",
            "sc"."full_name" AS "commission_full_name",
            "sc"."primary_role" AS "commission_primary_role",
            "sc"."remuneration_plan" AS "commission_remuneration_plan",
            "sc"."employment_type" AS "commission_employment_type",
            "sw"."display_name" AS "work_display_name",
            "sw"."full_name" AS "work_full_name",
            "sw"."primary_role" AS "work_primary_role",
            "sw"."remuneration_plan" AS "work_remuneration_plan",
            "sw"."employment_type" AS "work_employment_type",
            "rp"."plan_name" AS "commission_plan_name",
            "rp"."can_use_assistants" AS "commission_can_use_assistants"
           FROM (((("public"."sales_transactions" "st"
             LEFT JOIN "public"."product_master" "pm" ON (("lower"(TRIM(BOTH FROM "st"."product_service_name")) = "lower"(TRIM(BOTH FROM "pm"."product_description")))))
             LEFT JOIN LATERAL ( SELECT "sm"."id",
                    "sm"."full_name",
                    "sm"."display_name",
                    "sm"."primary_role",
                    "sm"."remuneration_plan",
                    "sm"."employment_type",
                    "sm"."is_active",
                    "sm"."first_seen_sale_date",
                    "sm"."last_seen_sale_date",
                    "sm"."notes",
                    "sm"."created_at",
                    "sm"."updated_at",
                    "sm"."secondary_roles",
                    "sm"."fte",
                    "sm"."employment_start_date",
                    "sm"."employment_end_date",
                    "sm"."contractor_company_name",
                    "sm"."contractor_gst_registered",
                    "sm"."contractor_ird_number",
                    "sm"."contractor_street_address",
                    "sm"."contractor_suburb",
                    "sm"."contractor_city_postcode"
                   FROM "public"."staff_members" "sm"
                  WHERE ((("st"."staff_commission_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_commission_id")) OR (("st"."staff_commission_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text") IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "st"."staff_commission_name")) = "lower"(TRIM(BOTH FROM "sm"."display_name"))) AND ("sm"."is_active" = true)))
                  ORDER BY
                        CASE
                            WHEN (("st"."staff_commission_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_commission_id")) THEN 0
                            ELSE 1
                        END
                 LIMIT 1) "sc" ON (true))
             LEFT JOIN LATERAL ( SELECT "sm"."id",
                    "sm"."full_name",
                    "sm"."display_name",
                    "sm"."primary_role",
                    "sm"."remuneration_plan",
                    "sm"."employment_type",
                    "sm"."is_active",
                    "sm"."first_seen_sale_date",
                    "sm"."last_seen_sale_date",
                    "sm"."notes",
                    "sm"."created_at",
                    "sm"."updated_at",
                    "sm"."secondary_roles",
                    "sm"."fte",
                    "sm"."employment_start_date",
                    "sm"."employment_end_date",
                    "sm"."contractor_company_name",
                    "sm"."contractor_gst_registered",
                    "sm"."contractor_ird_number",
                    "sm"."contractor_street_address",
                    "sm"."contractor_suburb",
                    "sm"."contractor_city_postcode"
                   FROM "public"."staff_members" "sm"
                  WHERE ((("st"."staff_work_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_work_id")) OR (("st"."staff_work_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text") IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "st"."staff_work_name")) = "lower"(TRIM(BOTH FROM "sm"."display_name"))) AND ("sm"."is_active" = true)))
                  ORDER BY
                        CASE
                            WHEN (("st"."staff_work_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_work_id")) THEN 0
                            ELSE 1
                        END
                 LIMIT 1) "sw" ON (true))
             LEFT JOIN "public"."remuneration_plans" "rp" ON (("lower"(TRIM(BOTH FROM "sc"."remuneration_plan")) = "lower"(TRIM(BOTH FROM "rp"."plan_name")))))
        ), "derived" AS (
         SELECT "b"."id",
            "b"."import_batch_id",
            "b"."raw_row_id",
            "b"."location_id",
            "b"."invoice",
            "b"."customer_name",
            "b"."sale_datetime",
            "b"."sale_date",
            "b"."day_name",
            "b"."month_start",
            "b"."month_num",
            "b"."product_service_name",
            "b"."product_master_id",
            "b"."raw_product_type",
            "b"."existing_product_type_actual",
            "b"."existing_product_type_short",
            "b"."existing_commission_product_service",
            "b"."quantity",
            "b"."price_ex_gst",
            "b"."price_incl_gst",
            "b"."price_gst_component",
            "b"."staff_commission_name",
            "b"."staff_work_name",
            "b"."existing_staff_paid_name",
            "b"."staff_commission_id",
            "b"."staff_work_id",
            "b"."staff_paid_id",
            "b"."staff_commission_type",
            "b"."staff_work_type",
            "b"."staff_paid_type",
            "b"."existing_assistant_usage_alert",
            "b"."staff_work_is_staff_paid",
            "b"."invoice_header",
            "b"."product_header",
            "b"."created_at",
            "b"."updated_at",
            "b"."master_product_description",
            "b"."master_product_type",
            "b"."commission_display_name",
            "b"."commission_full_name",
            "b"."commission_primary_role",
            "b"."commission_remuneration_plan",
            "b"."commission_employment_type",
            "b"."work_display_name",
            "b"."work_full_name",
            "b"."work_primary_role",
            "b"."work_remuneration_plan",
            "b"."work_employment_type",
            "b"."commission_plan_name",
            "b"."commission_can_use_assistants",
                CASE
                    WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                    WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                    WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                    CASE
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                        ELSE "b"."raw_product_type"
                    END
                    ELSE "b"."master_product_type"
                END AS "product_type_actual_derived",
                CASE
                    WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Prof. Prod.'::"text"
                    WHEN (
                    CASE
                        WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                        CASE
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                            ELSE "b"."raw_product_type"
                        END
                        ELSE "b"."master_product_type"
                    END = 'Retail Product'::"text") THEN 'Retail Prod.'::"text"
                    WHEN (
                    CASE
                        WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                        CASE
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                            ELSE "b"."raw_product_type"
                        END
                        ELSE "b"."master_product_type"
                    END = 'Professional Product'::"text") THEN 'Prof. Prod.'::"text"
                    WHEN (
                    CASE
                        WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                        CASE
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                            ELSE "b"."raw_product_type"
                        END
                        ELSE "b"."master_product_type"
                    END = 'Service'::"text") THEN 'Services'::"text"
                    ELSE
                    CASE
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        ELSE
                        CASE
                            WHEN (("b"."master_product_type" IS NOT NULL) AND (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) <> ''::"text")) THEN "b"."master_product_type"
                            ELSE "b"."raw_product_type"
                        END
                    END
                END AS "product_type_short_derived",
                CASE
                    WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Comm - Products'::"text"
                    WHEN (
                    CASE
                        WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                        CASE
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                            ELSE "b"."raw_product_type"
                        END
                        ELSE "b"."master_product_type"
                    END = 'Retail Product'::"text") THEN 'Comm - Products'::"text"
                    WHEN (
                    CASE
                        WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                        CASE
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                            ELSE "b"."raw_product_type"
                        END
                        ELSE "b"."master_product_type"
                    END = 'Professional Product'::"text") THEN 'Comm - Products'::"text"
                    WHEN (
                    CASE
                        WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                        CASE
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                            ELSE "b"."raw_product_type"
                        END
                        ELSE "b"."master_product_type"
                    END = 'Service'::"text") THEN 'Comm - Services'::"text"
                    ELSE '-'::"text"
                END AS "commission_product_service_derived",
                CASE
                    WHEN ("upper"(TRIM(BOTH FROM COALESCE("b"."work_primary_role", ''::"text"))) = 'INTERNAL'::"text") THEN NULL::"text"
                    WHEN (("upper"(TRIM(BOTH FROM COALESCE("b"."work_primary_role", ''::"text"))) = 'ASSISTANT'::"text") AND (COALESCE("b"."commission_can_use_assistants", false) = false)) THEN NULL::"text"
                    WHEN (("upper"(TRIM(BOTH FROM COALESCE("b"."work_primary_role", ''::"text"))) = 'ASSISTANT'::"text") AND (COALESCE("b"."commission_can_use_assistants", false) = true)) THEN "b"."staff_commission_name"
                    WHEN (("lower"(TRIM(BOTH FROM COALESCE("b"."work_remuneration_plan", ''::"text"))) = 'wage'::"text") AND (COALESCE("b"."raw_product_type", ''::"text") <> ALL (ARRAY['Voucher'::"text", 'Unclassified'::"text"])) AND (NOT ("lower"(TRIM(BOTH FROM COALESCE("b"."product_service_name", ''::"text"))) = ANY (ARRAY['green fee'::"text", 'redo'::"text", 'training product'::"text", 'miscellaneous'::"text"]))) AND (NOT ("upper"(COALESCE("b"."product_header", ''::"text")) ~~ '%TONER WITH OTHER SERVICE%'::"text")) AND (NOT ("upper"(COALESCE("b"."product_header", ''::"text")) ~~ '%BONDED EXTENSIONS%'::"text")) AND (NOT ("upper"(COALESCE("b"."product_header", ''::"text")) ~~ '%EXTENSIONS BONDS%'::"text")) AND (NOT ("upper"(COALESCE("b"."product_header", ''::"text")) ~~ '%EXTENSIONS (TAPES%'::"text")) AND (
                    CASE
                        WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                        CASE
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                            ELSE "b"."raw_product_type"
                        END
                        ELSE "b"."master_product_type"
                    END = 'Retail Product'::"text")) THEN "b"."staff_work_name"
                    WHEN ("lower"(TRIM(BOTH FROM COALESCE("b"."work_remuneration_plan", ''::"text"))) = 'wage'::"text") THEN NULL::"text"
                    ELSE "b"."staff_work_name"
                END AS "staff_paid_name_derived",
                CASE
                    WHEN (("upper"(TRIM(BOTH FROM COALESCE("b"."work_primary_role", ''::"text"))) = 'ASSISTANT'::"text") AND ("b"."commission_can_use_assistants" = false)) THEN 'Ineligible assistant usage'::"text"
                    ELSE NULL::"text"
                END AS "assistant_usage_alert_derived",
                CASE
                    WHEN ("b"."staff_commission_name" = "b"."staff_work_name") THEN 'Yes'::"text"
                    ELSE 'No'::"text"
                END AS "staff_work_is_staff_paid_dax_parity",
                CASE
                    WHEN ("lower"(TRIM(BOTH FROM COALESCE("b"."product_service_name", ''::"text"))) = 'green fee'::"text") THEN 'no_commission_greenfee'::"text"
                    WHEN ("lower"(TRIM(BOTH FROM COALESCE("b"."product_service_name", ''::"text"))) = 'redo'::"text") THEN 'no_commission_redo'::"text"
                    WHEN ("lower"(TRIM(BOTH FROM COALESCE("b"."product_service_name", ''::"text"))) = 'training product'::"text") THEN 'no_commission_trainingproduct'::"text"
                    WHEN ("lower"(TRIM(BOTH FROM COALESCE("b"."product_service_name", ''::"text"))) = 'miscellaneous'::"text") THEN 'no_commission_miscellaneousproduct'::"text"
                    WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Voucher'::"text") THEN 'no_commission_voucher'::"text"
                    WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Unclassified'::"text") THEN 'no_commission_unclassified'::"text"
                    WHEN ("upper"(COALESCE("b"."product_header", ''::"text")) ~~ '%TONER WITH OTHER SERVICE%'::"text") THEN 'toner_with_other_service'::"text"
                    WHEN ("upper"(COALESCE("b"."product_header", ''::"text")) ~~ '%BONDED EXTENSIONS%'::"text") THEN 'extensions_product'::"text"
                    WHEN ("upper"(COALESCE("b"."product_header", ''::"text")) ~~ '%EXTENSIONS BONDS%'::"text") THEN 'extensions_product'::"text"
                    WHEN ("upper"(COALESCE("b"."product_header", ''::"text")) ~~ '%EXTENSIONS (TAPES%'::"text") THEN 'extensions_service'::"text"
                    WHEN (
                    CASE
                        WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                        CASE
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                            ELSE "b"."raw_product_type"
                        END
                        ELSE "b"."master_product_type"
                    END = 'Retail Product'::"text") THEN 'retail_product'::"text"
                    WHEN (
                    CASE
                        WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                        CASE
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                            ELSE "b"."raw_product_type"
                        END
                        ELSE "b"."master_product_type"
                    END = 'Professional Product'::"text") THEN 'professional_product'::"text"
                    WHEN (
                    CASE
                        WHEN ("right"(COALESCE("b"."product_service_name", ''::"text"), 1) = '*'::"text") THEN 'Professional Product'::"text"
                        WHEN (COALESCE("b"."raw_product_type", ''::"text") = ANY (ARRAY['Unclassified'::"text", 'Voucher'::"text"])) THEN '-'::"text"
                        WHEN (("b"."master_product_type" IS NULL) OR (TRIM(BOTH FROM COALESCE("b"."master_product_type", ''::"text")) = ''::"text")) THEN
                        CASE
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Service'::"text") THEN 'Service'::"text"
                            WHEN (COALESCE("b"."raw_product_type", ''::"text") = 'Retail'::"text") THEN 'Retail Product'::"text"
                            ELSE "b"."raw_product_type"
                        END
                        ELSE "b"."master_product_type"
                    END = 'Service'::"text") THEN 'service'::"text"
                    ELSE NULL::"text"
                END AS "commission_category_final"
           FROM "base" "b"
        )
 SELECT "id",
    "import_batch_id",
    "raw_row_id",
    "location_id",
    "invoice",
    "customer_name",
    "sale_datetime",
    "sale_date",
    "day_name",
    "month_start",
    "month_num",
    "product_service_name",
    "product_master_id",
    "raw_product_type",
    "existing_product_type_actual",
    "existing_product_type_short",
    "existing_commission_product_service",
    "quantity",
    "price_ex_gst",
    "price_incl_gst",
    "price_gst_component",
    "staff_commission_name",
    "staff_work_name",
    "existing_staff_paid_name",
    "staff_commission_id",
    "staff_work_id",
    "staff_paid_id",
    "staff_commission_type",
    "staff_work_type",
    "staff_paid_type",
    "existing_assistant_usage_alert",
    "staff_work_is_staff_paid",
    "invoice_header",
    "product_header",
    "created_at",
    "updated_at",
    "master_product_description",
    "master_product_type",
    "commission_display_name",
    "commission_full_name",
    "commission_primary_role",
    "commission_remuneration_plan",
    "commission_employment_type",
    "work_display_name",
    "work_full_name",
    "work_primary_role",
    "work_remuneration_plan",
    "work_employment_type",
    "commission_plan_name",
    "commission_can_use_assistants",
    "product_type_actual_derived",
    "product_type_short_derived",
    "commission_product_service_derived",
    "staff_paid_name_derived",
    "assistant_usage_alert_derived",
    "staff_work_is_staff_paid_dax_parity",
    "commission_category_final"
   FROM "derived" "d";


ALTER VIEW "public"."v_sales_transactions_powerbi_parity" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_commission_calculations_core" AS
 WITH "parity" AS (
         SELECT "v_sales_transactions_powerbi_parity"."id",
            "v_sales_transactions_powerbi_parity"."import_batch_id",
            "v_sales_transactions_powerbi_parity"."raw_row_id",
            "v_sales_transactions_powerbi_parity"."location_id",
            "v_sales_transactions_powerbi_parity"."invoice",
            "v_sales_transactions_powerbi_parity"."customer_name",
            "v_sales_transactions_powerbi_parity"."sale_datetime",
            "v_sales_transactions_powerbi_parity"."sale_date",
            "v_sales_transactions_powerbi_parity"."day_name",
            "v_sales_transactions_powerbi_parity"."month_start",
            "v_sales_transactions_powerbi_parity"."month_num",
            "v_sales_transactions_powerbi_parity"."product_service_name",
            "v_sales_transactions_powerbi_parity"."product_master_id",
            "v_sales_transactions_powerbi_parity"."raw_product_type",
            "v_sales_transactions_powerbi_parity"."existing_product_type_actual",
            "v_sales_transactions_powerbi_parity"."existing_product_type_short",
            "v_sales_transactions_powerbi_parity"."existing_commission_product_service",
            "v_sales_transactions_powerbi_parity"."quantity",
            "v_sales_transactions_powerbi_parity"."price_ex_gst",
            "v_sales_transactions_powerbi_parity"."price_incl_gst",
            "v_sales_transactions_powerbi_parity"."price_gst_component",
            "v_sales_transactions_powerbi_parity"."staff_commission_name",
            "v_sales_transactions_powerbi_parity"."staff_work_name",
            "v_sales_transactions_powerbi_parity"."existing_staff_paid_name",
            "v_sales_transactions_powerbi_parity"."staff_commission_id",
            "v_sales_transactions_powerbi_parity"."staff_work_id",
            "v_sales_transactions_powerbi_parity"."staff_paid_id",
            "v_sales_transactions_powerbi_parity"."staff_commission_type",
            "v_sales_transactions_powerbi_parity"."staff_work_type",
            "v_sales_transactions_powerbi_parity"."staff_paid_type",
            "v_sales_transactions_powerbi_parity"."existing_assistant_usage_alert",
            "v_sales_transactions_powerbi_parity"."staff_work_is_staff_paid",
            "v_sales_transactions_powerbi_parity"."invoice_header",
            "v_sales_transactions_powerbi_parity"."product_header",
            "v_sales_transactions_powerbi_parity"."created_at",
            "v_sales_transactions_powerbi_parity"."updated_at",
            "v_sales_transactions_powerbi_parity"."master_product_description",
            "v_sales_transactions_powerbi_parity"."master_product_type",
            "v_sales_transactions_powerbi_parity"."commission_display_name",
            "v_sales_transactions_powerbi_parity"."commission_full_name",
            "v_sales_transactions_powerbi_parity"."commission_primary_role",
            "v_sales_transactions_powerbi_parity"."commission_remuneration_plan",
            "v_sales_transactions_powerbi_parity"."commission_employment_type",
            "v_sales_transactions_powerbi_parity"."work_display_name",
            "v_sales_transactions_powerbi_parity"."work_full_name",
            "v_sales_transactions_powerbi_parity"."work_primary_role",
            "v_sales_transactions_powerbi_parity"."work_remuneration_plan",
            "v_sales_transactions_powerbi_parity"."work_employment_type",
            "v_sales_transactions_powerbi_parity"."commission_plan_name",
            "v_sales_transactions_powerbi_parity"."commission_can_use_assistants",
            "v_sales_transactions_powerbi_parity"."product_type_actual_derived",
            "v_sales_transactions_powerbi_parity"."product_type_short_derived",
            "v_sales_transactions_powerbi_parity"."commission_product_service_derived",
            "v_sales_transactions_powerbi_parity"."staff_paid_name_derived",
            "v_sales_transactions_powerbi_parity"."assistant_usage_alert_derived",
            "v_sales_transactions_powerbi_parity"."staff_work_is_staff_paid_dax_parity",
            "v_sales_transactions_powerbi_parity"."commission_category_final"
           FROM "public"."v_sales_transactions_powerbi_parity"
        ), "paid_staff_resolved" AS (
         SELECT "p"."id",
            "p"."import_batch_id",
            "p"."raw_row_id",
            "p"."location_id",
            "p"."invoice",
            "p"."customer_name",
            "p"."sale_datetime",
            "p"."sale_date",
            "p"."day_name",
            "p"."month_start",
            "p"."month_num",
            "p"."product_service_name",
            "p"."product_master_id",
            "p"."raw_product_type",
            "p"."existing_product_type_actual",
            "p"."existing_product_type_short",
            "p"."existing_commission_product_service",
            "p"."quantity",
            "p"."price_ex_gst",
            "p"."price_incl_gst",
            "p"."price_gst_component",
            "p"."staff_commission_name",
            "p"."staff_work_name",
            "p"."existing_staff_paid_name",
            "p"."staff_commission_id",
            "p"."staff_work_id",
            "p"."staff_paid_id",
            "p"."staff_commission_type",
            "p"."staff_work_type",
            "p"."staff_paid_type",
            "p"."existing_assistant_usage_alert",
            "p"."staff_work_is_staff_paid",
            "p"."invoice_header",
            "p"."product_header",
            "p"."created_at",
            "p"."updated_at",
            "p"."master_product_description",
            "p"."master_product_type",
            "p"."commission_display_name",
            "p"."commission_full_name",
            "p"."commission_primary_role",
            "p"."commission_remuneration_plan",
            "p"."commission_employment_type",
            "p"."work_display_name",
            "p"."work_full_name",
            "p"."work_primary_role",
            "p"."work_remuneration_plan",
            "p"."work_employment_type",
            "p"."commission_plan_name",
            "p"."commission_can_use_assistants",
            "p"."product_type_actual_derived",
            "p"."product_type_short_derived",
            "p"."commission_product_service_derived",
            "p"."staff_paid_name_derived",
            "p"."assistant_usage_alert_derived",
            "p"."staff_work_is_staff_paid_dax_parity",
            "p"."commission_category_final",
            "sm_paid"."id" AS "derived_staff_paid_id",
            "sm_paid"."display_name" AS "derived_staff_paid_display_name",
            "sm_paid"."full_name" AS "derived_staff_paid_full_name",
            "sm_paid"."primary_role" AS "derived_staff_paid_primary_role",
            "sm_paid"."remuneration_plan" AS "derived_staff_paid_remuneration_plan",
            "sm_paid"."employment_type" AS "derived_staff_paid_employment_type",
            "rp_paid"."id" AS "derived_staff_paid_plan_id",
            "rp_paid"."plan_name" AS "derived_staff_paid_plan_name",
            "rp_commission"."id" AS "benchmark_commission_plan_id",
            "rp_commission"."plan_name" AS "benchmark_commission_plan_name"
           FROM ((("parity" "p"
             LEFT JOIN "public"."staff_members" "sm_paid" ON ((("p"."staff_paid_name_derived" IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "p"."staff_paid_name_derived")) = "lower"(TRIM(BOTH FROM "sm_paid"."display_name"))))))
             LEFT JOIN "public"."remuneration_plans" "rp_paid" ON ((("sm_paid"."remuneration_plan" IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "sm_paid"."remuneration_plan")) = "lower"(TRIM(BOTH FROM "rp_paid"."plan_name"))))))
             LEFT JOIN "public"."remuneration_plans" "rp_commission" ON (("lower"(TRIM(BOTH FROM "rp_commission"."plan_name")) = 'commission'::"text")))
        ), "rated" AS (
         SELECT "psr"."id",
            "psr"."import_batch_id",
            "psr"."raw_row_id",
            "psr"."location_id",
            "psr"."invoice",
            "psr"."customer_name",
            "psr"."sale_datetime",
            "psr"."sale_date",
            "psr"."day_name",
            "psr"."month_start",
            "psr"."month_num",
            "psr"."product_service_name",
            "psr"."product_master_id",
            "psr"."raw_product_type",
            "psr"."existing_product_type_actual",
            "psr"."existing_product_type_short",
            "psr"."existing_commission_product_service",
            "psr"."quantity",
            "psr"."price_ex_gst",
            "psr"."price_incl_gst",
            "psr"."price_gst_component",
            "psr"."staff_commission_name",
            "psr"."staff_work_name",
            "psr"."existing_staff_paid_name",
            "psr"."staff_commission_id",
            "psr"."staff_work_id",
            "psr"."staff_paid_id",
            "psr"."staff_commission_type",
            "psr"."staff_work_type",
            "psr"."staff_paid_type",
            "psr"."existing_assistant_usage_alert",
            "psr"."staff_work_is_staff_paid",
            "psr"."invoice_header",
            "psr"."product_header",
            "psr"."created_at",
            "psr"."updated_at",
            "psr"."master_product_description",
            "psr"."master_product_type",
            "psr"."commission_display_name",
            "psr"."commission_full_name",
            "psr"."commission_primary_role",
            "psr"."commission_remuneration_plan",
            "psr"."commission_employment_type",
            "psr"."work_display_name",
            "psr"."work_full_name",
            "psr"."work_primary_role",
            "psr"."work_remuneration_plan",
            "psr"."work_employment_type",
            "psr"."commission_plan_name",
            "psr"."commission_can_use_assistants",
            "psr"."product_type_actual_derived",
            "psr"."product_type_short_derived",
            "psr"."commission_product_service_derived",
            "psr"."staff_paid_name_derived",
            "psr"."assistant_usage_alert_derived",
            "psr"."staff_work_is_staff_paid_dax_parity",
            "psr"."commission_category_final",
            "psr"."derived_staff_paid_id",
            "psr"."derived_staff_paid_display_name",
            "psr"."derived_staff_paid_full_name",
            "psr"."derived_staff_paid_primary_role",
            "psr"."derived_staff_paid_remuneration_plan",
            "psr"."derived_staff_paid_employment_type",
            "psr"."derived_staff_paid_plan_id",
            "psr"."derived_staff_paid_plan_name",
            "psr"."benchmark_commission_plan_id",
            "psr"."benchmark_commission_plan_name",
            "apr"."rate" AS "actual_commission_rate",
            "tpr"."rate" AS "theoretical_commission_rate"
           FROM (("paid_staff_resolved" "psr"
             LEFT JOIN "public"."remuneration_plan_rates" "apr" ON ((("apr"."remuneration_plan_id" = "psr"."derived_staff_paid_plan_id") AND ("lower"(TRIM(BOTH FROM "apr"."commission_category")) = "lower"(TRIM(BOTH FROM "psr"."commission_category_final"))))))
             LEFT JOIN "public"."remuneration_plan_rates" "tpr" ON ((("tpr"."remuneration_plan_id" = "psr"."benchmark_commission_plan_id") AND ("lower"(TRIM(BOTH FROM "tpr"."commission_category")) = "lower"(TRIM(BOTH FROM "psr"."commission_category_final"))))))
        )
 SELECT "id",
    "import_batch_id",
    "raw_row_id",
    "location_id",
    "invoice",
    "customer_name",
    "sale_datetime",
    "sale_date",
    "day_name",
    "month_start",
    "month_num",
    "product_service_name",
    "product_master_id",
    "master_product_description",
    "master_product_type",
    "raw_product_type",
    "product_type_actual_derived",
    "product_type_short_derived",
    "commission_product_service_derived",
    "commission_category_final",
    "quantity",
    "price_ex_gst",
    "price_incl_gst",
    "price_gst_component",
    "staff_commission_name",
    "staff_work_name",
    "existing_staff_paid_name",
    "staff_paid_name_derived",
    "staff_commission_id",
    "staff_work_id",
    "staff_paid_id" AS "existing_staff_paid_id",
    "derived_staff_paid_id",
    "commission_display_name",
    "commission_full_name",
    "commission_primary_role",
    "commission_remuneration_plan",
    "work_display_name",
    "work_full_name",
    "work_primary_role",
    "work_remuneration_plan",
    "derived_staff_paid_display_name",
    "derived_staff_paid_full_name",
    "derived_staff_paid_primary_role",
    "derived_staff_paid_remuneration_plan",
    "derived_staff_paid_employment_type",
    "derived_staff_paid_plan_id",
    "derived_staff_paid_plan_name",
    "commission_can_use_assistants",
    "assistant_usage_alert_derived",
    "staff_work_is_staff_paid_dax_parity",
        CASE
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("staff_paid_name_derived", ''::"text"))) = 'internal'::"text") THEN true
            ELSE false
        END AS "is_internal_non_commission",
        CASE
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("commission_category_final", ''::"text"))) = ANY (ARRAY['no_commission_greenfee'::"text", 'no_commission_redo'::"text", 'no_commission_trainingproduct'::"text", 'no_commission_miscellaneousproduct'::"text", 'no_commission_voucher'::"text", 'no_commission_unclassified'::"text"])) THEN true
            ELSE false
        END AS "is_named_non_commission_category",
    "actual_commission_rate",
        CASE
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("commission_category_final", ''::"text"))) = ANY (ARRAY['no_commission_greenfee'::"text", 'no_commission_redo'::"text", 'no_commission_trainingproduct'::"text", 'no_commission_miscellaneousproduct'::"text", 'no_commission_voucher'::"text", 'no_commission_unclassified'::"text"])) THEN NULL::numeric
            WHEN (("lower"(TRIM(BOTH FROM COALESCE("staff_paid_name_derived", ''::"text"))) <> 'internal'::"text") AND ("staff_paid_name_derived" IS NOT NULL) AND (("derived_staff_paid_id" IS NULL) OR ("derived_staff_paid_plan_id" IS NULL))) THEN (0)::numeric
            WHEN (("price_ex_gst" IS NOT NULL) AND ("actual_commission_rate" IS NOT NULL)) THEN ("price_ex_gst" * "actual_commission_rate")
            ELSE NULL::numeric
        END AS "actual_commission_amt_ex_gst",
    "theoretical_commission_rate",
        CASE
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("commission_category_final", ''::"text"))) = ANY (ARRAY['no_commission_greenfee'::"text", 'no_commission_redo'::"text", 'no_commission_trainingproduct'::"text", 'no_commission_miscellaneousproduct'::"text", 'no_commission_voucher'::"text", 'no_commission_unclassified'::"text"])) THEN NULL::numeric
            WHEN (("lower"(TRIM(BOTH FROM COALESCE("staff_paid_name_derived", ''::"text"))) <> 'internal'::"text") AND ("staff_paid_name_derived" IS NOT NULL) AND (("derived_staff_paid_id" IS NULL) OR ("derived_staff_paid_plan_id" IS NULL))) THEN (0)::numeric
            WHEN (("price_ex_gst" IS NOT NULL) AND ("theoretical_commission_rate" IS NOT NULL)) THEN ("price_ex_gst" * "theoretical_commission_rate")
            ELSE NULL::numeric
        END AS "theoretical_commission_amt_ex_gst",
        CASE
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("commission_category_final", ''::"text"))) = ANY (ARRAY['no_commission_greenfee'::"text", 'no_commission_redo'::"text", 'no_commission_trainingproduct'::"text", 'no_commission_miscellaneousproduct'::"text", 'no_commission_voucher'::"text", 'no_commission_unclassified'::"text"])) THEN NULL::numeric
            WHEN (("lower"(TRIM(BOTH FROM COALESCE("staff_paid_name_derived", ''::"text"))) <> 'internal'::"text") AND ("staff_paid_name_derived" IS NOT NULL) AND (("derived_staff_paid_id" IS NULL) OR ("derived_staff_paid_plan_id" IS NULL))) THEN (0)::numeric
            WHEN (("upper"(TRIM(BOTH FROM COALESCE("work_primary_role", ''::"text"))) = 'ASSISTANT'::"text") AND ("commission_can_use_assistants" = true) AND ("price_ex_gst" IS NOT NULL) AND ("actual_commission_rate" IS NOT NULL)) THEN ("price_ex_gst" * "actual_commission_rate")
            ELSE NULL::numeric
        END AS "assistant_commission_amt_ex_gst",
        CASE
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("commission_category_final", ''::"text"))) = 'no_commission_greenfee'::"text") THEN 'no_commission_greenfee'::"text"
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("commission_category_final", ''::"text"))) = 'no_commission_redo'::"text") THEN 'no_commission_redo'::"text"
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("commission_category_final", ''::"text"))) = 'no_commission_trainingproduct'::"text") THEN 'no_commission_trainingproduct'::"text"
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("commission_category_final", ''::"text"))) = 'no_commission_miscellaneousproduct'::"text") THEN 'no_commission_miscellaneousproduct'::"text"
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("commission_category_final", ''::"text"))) = 'no_commission_voucher'::"text") THEN 'no_commission_voucher'::"text"
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("commission_category_final", ''::"text"))) = 'no_commission_unclassified'::"text") THEN 'no_commission_unclassified'::"text"
            WHEN ("lower"(TRIM(BOTH FROM COALESCE("staff_paid_name_derived", ''::"text"))) = 'internal'::"text") THEN 'non_commission_internal'::"text"
            WHEN (("staff_paid_name_derived" IS NULL) AND ("assistant_usage_alert_derived" = 'Ineligible assistant usage'::"text")) THEN 'blocked_ineligible_assistant_usage'::"text"
            WHEN ("staff_paid_name_derived" IS NULL) THEN 'no_paid_staff_derived'::"text"
            WHEN (("staff_paid_name_derived" IS NOT NULL) AND (("derived_staff_paid_id" IS NULL) OR ("derived_staff_paid_plan_id" IS NULL))) THEN 'non_commission_unconfigured_paid_staff'::"text"
            WHEN ("commission_category_final" IS NULL) THEN 'commission_category_not_derived'::"text"
            WHEN ("actual_commission_rate" IS NULL) THEN 'commission_rate_not_found'::"text"
            ELSE NULL::"text"
        END AS "calculation_alert",
    "invoice_header",
    "product_header",
    "created_at",
    "updated_at"
   FROM "rated";


ALTER VIEW "public"."v_commission_calculations_core" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_commission_calculations_qa" AS
 SELECT "id",
    "import_batch_id",
    "raw_row_id",
    "location_id",
    "invoice",
    "customer_name",
    "sale_datetime",
    "sale_date",
    "day_name",
    "month_start",
    "month_num",
    "product_service_name",
    "product_master_id",
    "master_product_description",
    "master_product_type",
    "raw_product_type",
    "product_type_actual_derived",
    "product_type_short_derived",
    "commission_product_service_derived",
    "commission_category_final",
    "quantity",
    "price_ex_gst",
    "price_incl_gst",
    "price_gst_component",
    "staff_commission_name",
    "staff_work_name",
    "existing_staff_paid_name",
    "staff_paid_name_derived",
    "staff_commission_id",
    "staff_work_id",
    "existing_staff_paid_id",
    "derived_staff_paid_id",
    "commission_display_name",
    "commission_full_name",
    "commission_primary_role",
    "commission_remuneration_plan",
    "work_display_name",
    "work_full_name",
    "work_primary_role",
    "work_remuneration_plan",
    "derived_staff_paid_display_name",
    "derived_staff_paid_full_name",
    "derived_staff_paid_primary_role",
    "derived_staff_paid_remuneration_plan",
    "derived_staff_paid_employment_type",
    "derived_staff_paid_plan_id",
    "derived_staff_paid_plan_name",
    "commission_can_use_assistants",
    "assistant_usage_alert_derived",
    "staff_work_is_staff_paid_dax_parity",
    "is_internal_non_commission",
    "is_named_non_commission_category",
    "actual_commission_rate",
    "actual_commission_amt_ex_gst",
    "theoretical_commission_rate",
    "theoretical_commission_amt_ex_gst",
    "assistant_commission_amt_ex_gst",
    "calculation_alert",
    "invoice_header",
    "product_header",
    "created_at",
    "updated_at",
        CASE
            WHEN ("calculation_alert" IS NULL) THEN 'clean_commission_row'::"text"
            WHEN ("calculation_alert" = ANY (ARRAY['no_commission_greenfee'::"text", 'no_commission_redo'::"text", 'no_commission_trainingproduct'::"text", 'no_commission_miscellaneousproduct'::"text", 'no_commission_voucher'::"text", 'no_commission_unclassified'::"text", 'non_commission_internal'::"text", 'non_commission_unconfigured_paid_staff'::"text"])) THEN 'expected_non_commission'::"text"
            WHEN ("calculation_alert" = 'paid_staff_plan_not_matched'::"text") THEN 'configuration_issue'::"text"
            ELSE 'unexpected_issue'::"text"
        END AS "qa_bucket",
        CASE
            WHEN ("calculation_alert" IS NULL) THEN 0
            WHEN ("calculation_alert" = ANY (ARRAY['no_commission_greenfee'::"text", 'no_commission_redo'::"text", 'no_commission_trainingproduct'::"text", 'no_commission_miscellaneousproduct'::"text", 'no_commission_voucher'::"text", 'no_commission_unclassified'::"text", 'non_commission_internal'::"text", 'non_commission_unconfigured_paid_staff'::"text"])) THEN 1
            WHEN ("calculation_alert" = 'paid_staff_plan_not_matched'::"text") THEN 2
            ELSE 3
        END AS "qa_priority"
   FROM "public"."v_commission_calculations_core" "c";


ALTER VIEW "public"."v_commission_calculations_qa" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_admin_payroll_lines" AS
 SELECT "id",
    "import_batch_id",
    "raw_row_id",
    "location_id",
    "invoice",
    "sale_datetime",
    "sale_date",
    "day_name",
    "month_start",
    "month_num",
    "customer_name",
    "product_service_name",
    "product_master_id",
    "master_product_description",
    "master_product_type",
    "raw_product_type",
    "product_type_actual_derived" AS "product_type_actual",
    "product_type_short_derived" AS "product_type_short",
    "commission_product_service_derived" AS "commission_product_service",
    "commission_category_final",
    "quantity",
    "price_ex_gst",
    "price_incl_gst",
    "price_gst_component",
    "staff_commission_name",
    "staff_work_name",
    "existing_staff_paid_name",
    "staff_paid_name_derived",
    "staff_commission_id",
    "staff_work_id",
    "existing_staff_paid_id",
    "derived_staff_paid_id",
    "commission_display_name",
    "commission_full_name",
    "commission_primary_role",
    "commission_remuneration_plan",
    "work_display_name",
    "work_full_name",
    "work_primary_role",
    "work_remuneration_plan",
    "derived_staff_paid_display_name",
    "derived_staff_paid_full_name",
    "derived_staff_paid_primary_role",
    "derived_staff_paid_remuneration_plan",
    "derived_staff_paid_employment_type",
    "derived_staff_paid_plan_id",
    "derived_staff_paid_plan_name",
    "commission_can_use_assistants",
    "assistant_usage_alert_derived",
    "staff_work_is_staff_paid_dax_parity",
    "is_internal_non_commission",
    "is_named_non_commission_category",
    "actual_commission_rate",
    "actual_commission_amt_ex_gst",
    "theoretical_commission_rate",
    "theoretical_commission_amt_ex_gst",
    "assistant_commission_amt_ex_gst",
    "calculation_alert",
    "qa_bucket",
    "qa_priority",
        CASE
            WHEN (("qa_bucket" = 'clean_commission_row'::"text") AND (COALESCE("actual_commission_amt_ex_gst", (0)::numeric) <> (0)::numeric)) THEN 'payable'::"text"
            WHEN (("qa_bucket" = 'clean_commission_row'::"text") AND (COALESCE("actual_commission_amt_ex_gst", (0)::numeric) = (0)::numeric)) THEN 'zero_value_commission_row'::"text"
            WHEN ("qa_bucket" = 'expected_non_commission'::"text") THEN 'expected_no_commission'::"text"
            WHEN ("qa_bucket" = 'configuration_issue'::"text") THEN 'hold_config_issue'::"text"
            WHEN ("qa_bucket" = 'unexpected_issue'::"text") THEN 'hold_unexpected_issue'::"text"
            ELSE 'hold_unknown'::"text"
        END AS "payroll_status",
        CASE
            WHEN (("qa_bucket" = 'clean_commission_row'::"text") AND (COALESCE("actual_commission_amt_ex_gst", (0)::numeric) <> (0)::numeric)) THEN true
            ELSE false
        END AS "is_payable",
        CASE
            WHEN ("qa_bucket" = ANY (ARRAY['configuration_issue'::"text", 'unexpected_issue'::"text"])) THEN true
            ELSE false
        END AS "requires_review",
    "invoice_header",
    "product_header",
    "created_at",
    "updated_at"
   FROM "public"."v_commission_calculations_qa" "q";


ALTER VIEW "public"."v_admin_payroll_lines" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_admin_payroll_lines_weekly" AS
 SELECT "l"."id",
    "l"."import_batch_id",
    "l"."raw_row_id",
    "l"."location_id",
    "l"."invoice",
    "l"."sale_datetime",
    "l"."sale_date",
    "l"."day_name",
    "l"."month_start",
    "l"."month_num",
    "l"."customer_name",
    "l"."product_service_name",
    "l"."product_master_id",
    "l"."master_product_description",
    "l"."master_product_type",
    "l"."raw_product_type",
    "l"."product_type_actual",
    "l"."product_type_short",
    "l"."commission_product_service",
    "l"."commission_category_final",
    "l"."quantity",
    "l"."price_ex_gst",
    "l"."price_incl_gst",
    "l"."price_gst_component",
    "l"."staff_commission_name",
    "l"."staff_work_name",
    "l"."existing_staff_paid_name",
    "l"."staff_paid_name_derived",
    "l"."staff_commission_id",
    "l"."staff_work_id",
    "l"."existing_staff_paid_id",
    "l"."derived_staff_paid_id",
    "l"."commission_display_name",
    "l"."commission_full_name",
    "l"."commission_primary_role",
    "l"."commission_remuneration_plan",
    "l"."work_display_name",
    "l"."work_full_name",
    "l"."work_primary_role",
    "l"."work_remuneration_plan",
    "l"."derived_staff_paid_display_name",
    "l"."derived_staff_paid_full_name",
    "l"."derived_staff_paid_primary_role",
    "l"."derived_staff_paid_remuneration_plan",
    "l"."derived_staff_paid_employment_type",
    "l"."derived_staff_paid_plan_id",
    "l"."derived_staff_paid_plan_name",
    "l"."commission_can_use_assistants",
    "l"."assistant_usage_alert_derived",
    "l"."staff_work_is_staff_paid_dax_parity",
    "l"."is_internal_non_commission",
    "l"."is_named_non_commission_category",
    "l"."actual_commission_rate",
    "l"."actual_commission_amt_ex_gst",
    "l"."theoretical_commission_rate",
    "l"."theoretical_commission_amt_ex_gst",
    "l"."assistant_commission_amt_ex_gst",
    "l"."calculation_alert",
    "l"."qa_bucket",
    "l"."qa_priority",
    "l"."payroll_status",
    "l"."is_payable",
    "l"."requires_review",
    "l"."invoice_header",
    "l"."product_header",
    "l"."created_at",
    "l"."updated_at",
    (("l"."sale_date" - ((((EXTRACT(isodow FROM "l"."sale_date"))::integer - 1))::double precision * '1 day'::interval)))::"date" AS "pay_week_start",
    ((("l"."sale_date" - ((((EXTRACT(isodow FROM "l"."sale_date"))::integer - 1))::double precision * '1 day'::interval)) + '6 days'::interval))::"date" AS "pay_week_end",
    ((("l"."sale_date" - ((((EXTRACT(isodow FROM "l"."sale_date"))::integer - 1))::double precision * '1 day'::interval)) + '10 days'::interval))::"date" AS "pay_date",
    "loc"."name" AS "location_name"
   FROM ("public"."v_admin_payroll_lines" "l"
     LEFT JOIN "public"."locations" "loc" ON (("loc"."id" = "l"."location_id")));


ALTER VIEW "public"."v_admin_payroll_lines_weekly" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_payroll_lines_weekly"("p_pay_week_start" "date") RETURNS SETOF "public"."v_admin_payroll_lines_weekly"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select *
  from public.v_admin_payroll_lines_weekly
  where public.fn_is_admin_or_manager()
    and pay_week_start = p_pay_week_start
  order by location_id, sale_date desc, invoice, id
$$;


ALTER FUNCTION "public"."get_admin_payroll_lines_weekly"("p_pay_week_start" "date") OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_admin_payroll_summary_weekly" AS
 SELECT "pay_week_start",
    "pay_week_end",
    "pay_date",
    "location_id",
    "derived_staff_paid_id",
    "derived_staff_paid_display_name",
    "derived_staff_paid_full_name",
    "derived_staff_paid_remuneration_plan",
    "count"(*) AS "line_count",
    "count"(*) FILTER (WHERE ("payroll_status" = 'payable'::"text")) AS "payable_line_count",
    "count"(*) FILTER (WHERE ("payroll_status" = 'expected_no_commission'::"text")) AS "expected_no_commission_line_count",
    "count"(*) FILTER (WHERE ("payroll_status" = 'zero_value_commission_row'::"text")) AS "zero_value_line_count",
    "count"(*) FILTER (WHERE ("requires_review" = true)) AS "review_line_count",
    "round"("sum"(COALESCE("price_ex_gst", (0)::numeric)), 2) AS "total_sales_ex_gst",
    "round"("sum"(COALESCE("actual_commission_amt_ex_gst", (0)::numeric)), 2) AS "total_actual_commission_ex_gst",
    "round"("sum"(COALESCE("theoretical_commission_amt_ex_gst", (0)::numeric)), 2) AS "total_theoretical_commission_ex_gst",
    "round"("sum"(COALESCE("assistant_commission_amt_ex_gst", (0)::numeric)), 2) AS "total_assistant_commission_ex_gst",
    "count"(*) FILTER (WHERE ("calculation_alert" = 'non_commission_unconfigured_paid_staff'::"text")) AS "unconfigured_paid_staff_line_count",
    COALESCE("bool_or"(("calculation_alert" = 'non_commission_unconfigured_paid_staff'::"text")), false) AS "has_unconfigured_paid_staff_rows",
    "location_name"
   FROM "public"."v_admin_payroll_lines_weekly"
  GROUP BY "pay_week_start", "pay_week_end", "pay_date", "location_id", "derived_staff_paid_id", "derived_staff_paid_display_name", "derived_staff_paid_full_name", "derived_staff_paid_remuneration_plan", "location_name";


ALTER VIEW "public"."v_admin_payroll_summary_weekly" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_payroll_summary_weekly"() RETURNS SETOF "public"."v_admin_payroll_summary_weekly"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public.fn_is_admin_or_manager() then
    raise exception 'Access denied';
  end if;

  return query
  select *
  from public.v_admin_payroll_summary_weekly
  order by pay_week_start desc, location_id, derived_staff_paid_display_name;
end;
$$;


ALTER FUNCTION "public"."get_admin_payroll_summary_weekly"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_kpi_guests_per_month_live"("p_period_start" "date" DEFAULT NULL::"date", "p_scope" "text" DEFAULT 'business'::"text", "p_location_id" "uuid" DEFAULT NULL::"uuid", "p_staff_member_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("kpi_code" "text", "scope_type" "text", "location_id" "uuid", "staff_member_id" "uuid", "period_start" "date", "period_end" "date", "mtd_through" "date", "is_current_open_month" boolean, "value" numeric, "value_numerator" numeric, "value_denominator" numeric, "source" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_kpi_guests_per_month_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_kpi_guests_per_month_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") IS 'Live distinct-guest count KPI for the current open month (or any past month). Identity = public.normalise_customer_name(sales_transactions.customer_name). Stylist/assistant callers are silently restricted to their own staff scope. Does not read or write kpi_monthly_values.';



CREATE OR REPLACE FUNCTION "public"."get_kpi_revenue_live"("p_period_start" "date" DEFAULT NULL::"date", "p_scope" "text" DEFAULT 'business'::"text", "p_location_id" "uuid" DEFAULT NULL::"uuid", "p_staff_member_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("kpi_code" "text", "scope_type" "text", "location_id" "uuid", "staff_member_id" "uuid", "period_start" "date", "period_end" "date", "mtd_through" "date", "is_current_open_month" boolean, "value" numeric, "value_numerator" numeric, "value_denominator" numeric, "source" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_kpi_revenue_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_kpi_revenue_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") IS 'Live revenue (ex GST) KPI for the current open month (or any past month, computed live from v_sales_transactions_enriched). Stylist/assistant callers are silently restricted to their own staff scope. Does not read or write kpi_monthly_values.';



CREATE OR REPLACE FUNCTION "public"."get_location_id_from_filename"("p_file_name" "text") RETURNS "uuid"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_file_name text;
  v_location_id uuid;
begin
  v_file_name := lower(coalesce(p_file_name, ''));

  if position('orewa' in v_file_name) > 0 then
    select id into v_location_id
    from public.locations
    where code = 'ORE';

  elsif position('takapuna' in v_file_name) > 0 then
    select id into v_location_id
    from public.locations
    where code = 'TAK';

  else
    raise exception 'Could not determine location from file name: %', p_file_name;
  end if;

  if v_location_id is null then
    raise exception 'Matching location code was found in the file name, but no row exists in public.locations for file name: %', p_file_name;
  end if;

  return v_location_id;
end;
$$;


ALTER FUNCTION "public"."get_location_id_from_filename"("p_file_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_access_profile"() RETURNS TABLE("user_id" "uuid", "email" "text", "staff_member_id" "uuid", "staff_display_name" "text", "staff_full_name" "text", "access_role" "text", "is_active" boolean)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    v.user_id,
    v.email,
    v.staff_member_id,
    v.staff_display_name,
    v.staff_full_name,
    v.access_role,
    v.is_active
  from public.v_admin_user_access_overview v
  where v.user_id = auth.uid()
    and v.is_active = true
  order by v.staff_full_name nulls last
  limit 1
$$;


ALTER FUNCTION "public"."get_my_access_profile"() OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_stylist_commission_lines_weekly_final" AS
 SELECT "a"."user_id",
    "l"."id",
    "l"."import_batch_id",
    "l"."raw_row_id",
    "l"."location_id",
    "l"."invoice",
    "l"."sale_datetime",
    "l"."sale_date",
    "l"."day_name",
    "l"."month_start",
    "l"."month_num",
    "l"."pay_week_start",
    "l"."pay_week_end",
    "l"."pay_date",
    "l"."customer_name",
    "l"."product_service_name",
    "l"."product_type_actual",
    "l"."product_type_short",
    "l"."commission_product_service",
    "l"."commission_category_final",
    "l"."quantity",
    "l"."price_ex_gst",
    "l"."price_incl_gst",
    "l"."derived_staff_paid_id",
    "l"."derived_staff_paid_display_name",
    "l"."derived_staff_paid_full_name",
    "l"."actual_commission_rate",
    "l"."actual_commission_amt_ex_gst",
    "l"."assistant_commission_amt_ex_gst",
    "l"."payroll_status",
        CASE
            WHEN ("l"."payroll_status" = 'expected_no_commission'::"text") THEN "l"."calculation_alert"
            WHEN ("l"."payroll_status" = 'zero_value_commission_row'::"text") THEN 'zero_commission_row'::"text"
            ELSE NULL::"text"
        END AS "stylist_visible_note",
    "a"."access_role",
    "l"."location_name"
   FROM ("public"."v_admin_payroll_lines_weekly" "l"
     JOIN "public"."staff_member_user_access" "a" ON ((("a"."is_active" = true) AND ((("a"."access_role" = ANY (ARRAY['stylist'::"text", 'assistant'::"text"])) AND ("a"."staff_member_id" = "l"."derived_staff_paid_id")) OR ("a"."access_role" = ANY (ARRAY['manager'::"text", 'admin'::"text"]))))))
  WHERE (("l"."derived_staff_paid_id" IS NOT NULL) AND (COALESCE("lower"(TRIM(BOTH FROM "l"."derived_staff_paid_display_name")), ''::"text") <> 'internal'::"text") AND (COALESCE("l"."calculation_alert", ''::"text") <> 'non_commission_unconfigured_paid_staff'::"text"));


ALTER VIEW "public"."v_stylist_commission_lines_weekly_final" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_commission_lines_weekly"("p_pay_week_start" "date") RETURNS SETOF "public"."v_stylist_commission_lines_weekly_final"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select *
  from public.v_stylist_commission_lines_weekly_final
  where user_id = auth.uid()
    and pay_week_start = p_pay_week_start
  order by location_id, sale_date desc, invoice, id
$$;


ALTER FUNCTION "public"."get_my_commission_lines_weekly"("p_pay_week_start" "date") OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_stylist_commission_summary_weekly_final" AS
 SELECT "a"."user_id",
    "w"."pay_week_start",
    "w"."pay_week_end",
    "w"."pay_date",
    "w"."location_id",
    "w"."derived_staff_paid_id",
    "w"."derived_staff_paid_display_name",
    "w"."derived_staff_paid_full_name",
    "w"."derived_staff_paid_remuneration_plan",
    "w"."line_count",
    "w"."payable_line_count",
    "w"."expected_no_commission_line_count",
    "w"."zero_value_line_count",
    "w"."review_line_count",
    "w"."total_sales_ex_gst",
    "w"."total_actual_commission_ex_gst",
    "w"."total_theoretical_commission_ex_gst",
    "w"."total_assistant_commission_ex_gst",
    "w"."unconfigured_paid_staff_line_count",
    "w"."has_unconfigured_paid_staff_rows",
    "a"."access_role",
    "w"."location_name"
   FROM ("public"."v_admin_payroll_summary_weekly" "w"
     JOIN "public"."staff_member_user_access" "a" ON ((("a"."is_active" = true) AND ((("a"."access_role" = ANY (ARRAY['stylist'::"text", 'assistant'::"text"])) AND ("a"."staff_member_id" = "w"."derived_staff_paid_id")) OR ("a"."access_role" = ANY (ARRAY['manager'::"text", 'admin'::"text"]))))))
  WHERE (("w"."derived_staff_paid_id" IS NOT NULL) AND (COALESCE("lower"(TRIM(BOTH FROM "w"."derived_staff_paid_display_name")), ''::"text") <> 'internal'::"text") AND ("w"."has_unconfigured_paid_staff_rows" = false));


ALTER VIEW "public"."v_stylist_commission_summary_weekly_final" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_commission_summary_weekly"() RETURNS SETOF "public"."v_stylist_commission_summary_weekly_final"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select *
  from public.v_stylist_commission_summary_weekly_final
  where user_id = auth.uid()
  order by pay_week_start desc, location_id, derived_staff_paid_display_name
$$;


ALTER FUNCTION "public"."get_my_commission_summary_weekly"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_saved_quote_detail"("p_saved_quote_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_saved_quote_detail"("p_saved_quote_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_saved_quotes_search"("p_search" "text" DEFAULT NULL::"text", "p_stylist" "text" DEFAULT NULL::"text", "p_guest_name" "text" DEFAULT NULL::"text", "p_date_from" "date" DEFAULT NULL::"date", "p_date_to" "date" DEFAULT NULL::"date", "p_limit" integer DEFAULT 100, "p_offset" integer DEFAULT 0) RETURNS TABLE("id" "uuid", "created_at" timestamp with time zone, "quote_date" "date", "guest_name" "text", "stylist_user_id" "uuid", "stylist_display_name" "text", "notes_preview" "text", "grand_total" numeric, "line_count" bigint, "total_count" bigint)
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."get_saved_quotes_search"("p_search" "text", "p_stylist" "text", "p_guest_name" "text", "p_date_from" "date", "p_date_to" "date", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_sales_daily_sheets_staged_rows_chunk"("p_rows" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
BEGIN
  PERFORM set_config('statement_timeout', '0', true);

  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'insert_sales_daily_sheets_staged_rows_chunk: p_rows must be a JSON array';
  END IF;

  INSERT INTO public.sales_daily_sheets_staged_rows (
    batch_id,
    line_number,
    invoice,
    sale_date,
    pay_week_start,
    pay_week_end,
    pay_date,
    customer_name,
    product_service_name,
    quantity,
    price_ex_gst,
    derived_staff_paid_display_name,
    actual_commission_amount,
    assistant_commission_amount,
    payroll_status,
    stylist_visible_note,
    location_id,
    extras
  )
  SELECT
    (elem->>'batch_id')::uuid,
    (elem->>'line_number')::integer,
    nullif(elem->>'invoice', ''),
    nullif(elem->>'sale_date', ''),
    CASE
      WHEN coalesce(nullif(trim(elem->>'pay_week_start'), ''), '') = '' THEN NULL
      ELSE (elem->>'pay_week_start')::date
    END,
    CASE
      WHEN coalesce(nullif(trim(elem->>'pay_week_end'), ''), '') = '' THEN NULL
      ELSE (elem->>'pay_week_end')::date
    END,
    CASE
      WHEN coalesce(nullif(trim(elem->>'pay_date'), ''), '') = '' THEN NULL
      ELSE (elem->>'pay_date')::date
    END,
    nullif(elem->>'customer_name', ''),
    nullif(elem->>'product_service_name', ''),
    nullif(elem->>'quantity', '')::numeric,
    nullif(elem->>'price_ex_gst', '')::numeric,
    nullif(elem->>'derived_staff_paid_display_name', ''),
    nullif(elem->>'actual_commission_amount', '')::numeric,
    nullif(elem->>'assistant_commission_amount', '')::numeric,
    nullif(elem->>'payroll_status', ''),
    nullif(elem->>'stylist_visible_note', ''),
    CASE
      WHEN elem ? 'location_id'
        AND coalesce(elem->>'location_id', '') <> ''
        AND (elem->>'location_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
      THEN (elem->>'location_id')::uuid
      ELSE NULL
    END,
    coalesce(elem->'extras', '{}'::jsonb)
  FROM jsonb_array_elements(p_rows) AS _(elem);
END;
$_$;


ALTER FUNCTION "public"."insert_sales_daily_sheets_staged_rows_chunk"("p_rows" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."insert_sales_daily_sheets_staged_rows_chunk"("p_rows" "jsonb") IS 'Used by Edge sales-daily-sheets-import: bulk insert staged rows with statement_timeout disabled.';



CREATE OR REPLACE FUNCTION "public"."insert_staged_sales_row"("p_category" "text", "p_first_name" "text", "p_qty" "text", "p_prod_total" "text", "p_prod_id" "text", "p_date" "text", "p_source_document_number" "text", "p_description" "text", "p_whole_name" "text", "p_product_type" "text", "p_parent_prod_type" "text", "p_prod_cat" "text", "p_name" "text") RETURNS "void"
    LANGUAGE "sql"
    AS $$
  insert into public.stg_salesdailysheets (
    "CATEGORY",
    "FIRST_NAME",
    "QTY",
    "PROD_TOTAL",
    "PROD_ID",
    "DATE",
    "SOURCE_DOCUMENT_NUMBER",
    "DESCRIPTION",
    "WHOLE_NAME",
    "PRODUCT_TYPE",
    "PARENT_PROD_TYPE",
    "PROD_CAT",
    "NAME"
  )
  values (
    p_category,
    p_first_name,
    p_qty,
    p_prod_total,
    p_prod_id,
    p_date,
    p_source_document_number,
    p_description,
    p_whole_name,
    p_product_type,
    p_parent_prod_type,
    p_prod_cat,
    p_name
  );
$$;


ALTER FUNCTION "public"."insert_staged_sales_row"("p_category" "text", "p_first_name" "text", "p_qty" "text", "p_prod_total" "text", "p_prod_id" "text", "p_date" "text", "p_source_document_number" "text", "p_description" "text", "p_whole_name" "text", "p_product_type" "text", "p_parent_prod_type" "text", "p_prod_cat" "text", "p_name" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_active_locations_for_import"() RETURNS TABLE("id" "uuid", "code" "text", "name" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF auth.uid() IS NULL OR NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  RETURN QUERY
  SELECT l.id, l.code, l.name
  FROM public.locations l
  WHERE l.is_active = true
  ORDER BY l.name;
END;
$$;


ALTER FUNCTION "public"."list_active_locations_for_import"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."list_active_locations_for_import"() IS 'Active locations for Admin Imports dropdown (elevated users only).';



CREATE OR REPLACE FUNCTION "public"."load_raw_sales_rows_to_transactions"("p_import_batch_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
declare
  v_count integer;
begin
  insert into public.sales_transactions (
    import_batch_id,
    raw_row_id,
    location_id,
    invoice,
    customer_name,
    sale_datetime,
    sale_date,
    day_name,
    month_start,
    month_num,
    product_service_name,
    raw_product_type,
    product_type_actual,
    product_type_short,
    commission_product_service,
    quantity,
    price_ex_gst,
    price_incl_gst,
    price_gst_component,
    staff_commission_name,
    staff_work_name,
    staff_paid_name,
    staff_commission_id,
    staff_work_id,
    staff_work_is_staff_paid,
    invoice_header,
    product_header
  )
  select
    r.import_batch_id,
    r.id,
    b.location_id,
    r.source_document_number as invoice,
    r.whole_name as customer_name,
    r.sale_datetime,
    (r.sale_datetime at time zone 'Pacific/Auckland')::date as sale_date,
    trim(to_char((r.sale_datetime at time zone 'Pacific/Auckland')::date, 'Day')) as day_name,
    date_trunc('month', (r.sale_datetime at time zone 'Pacific/Auckland'))::date as month_start,
    extract(month from (r.sale_datetime at time zone 'Pacific/Auckland'))::integer as month_num,
    r.description as product_service_name,
    r.product_type as raw_product_type,
    r.product_type as product_type_actual,
    case
      when lower(coalesce(r.product_type, '')) = 'service' then 'Service'
      when lower(coalesce(r.product_type, '')) = 'retail' then 'Retail'
      when lower(coalesce(r.product_type, '')) = 'product' then 'Retail'
      else r.product_type
    end as product_type_short,
    case
      when lower(coalesce(r.product_type, '')) = 'service' then 'Service'
      when lower(coalesce(r.product_type, '')) = 'retail' then 'Retail'
      when lower(coalesce(r.product_type, '')) = 'product' then 'Retail'
      else r.product_type
    end as commission_product_service,
    r.qty as quantity,
    r.prod_total as price_ex_gst,
    case
      when r.prod_total is null then null
      else round((r.prod_total * 1.15)::numeric, 2)
    end as price_incl_gst,
    case
      when r.prod_total is null then null
      else round(((r.prod_total * 1.15) - r.prod_total)::numeric, 2)
    end as price_gst_component,
    nullif(trim(r.first_name), '') as staff_commission_name,
    nullif(trim(r.staff_work_name), '') as staff_work_name,
    null::text as staff_paid_name,
    (
      select sm.id
      from public.staff_members sm
      where nullif(trim(r.first_name), '') is not null
        and lower(trim(sm.display_name)) = lower(trim(r.first_name))
        and sm.is_active = true
      limit 1
    ) as staff_commission_id,
    (
      select sm.id
      from public.staff_members sm
      where nullif(trim(r.staff_work_name), '') is not null
        and lower(trim(sm.display_name)) = lower(trim(r.staff_work_name))
        and sm.is_active = true
      limit 1
    ) as staff_work_id,
    case
      when nullif(trim(r.staff_work_name), '') is not null
        and nullif(trim(r.first_name), '') is not null
        and lower(trim(r.staff_work_name)) = lower(trim(r.first_name)) then 'Yes'
      else 'No'
    end as staff_work_is_staff_paid,
    coalesce(r.source_document_number, '') || ' | ' || coalesce(r.whole_name, '') as invoice_header,
    coalesce(r.description, '') || ' | ' || coalesce(r.staff_work_name, '') as product_header
  from public.raw_sales_import_rows r
  join public.sales_import_batches b
    on b.id = r.import_batch_id
  where r.import_batch_id = p_import_batch_id
  on conflict (raw_row_id) do nothing;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;


ALTER FUNCTION "public"."load_raw_sales_rows_to_transactions"("p_import_batch_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."load_staged_sales_rows_to_raw"("p_import_batch_id" "uuid") RETURNS integer
    LANGUAGE "plpgsql"
    AS $_$
declare
  v_count integer;
begin
  insert into public.raw_sales_import_rows (
    import_batch_id,
    category,
    first_name,
    qty,
    prod_total,
    prod_id,
    sale_datetime,
    source_document_number,
    description,
    whole_name,
    product_type,
    parent_prod_type,
    prod_cat,
    staff_work_name,
    raw_location,
    row_num,
    raw_payload
  )
  select
    p_import_batch_id,

    case
      when nullif(btrim("CATEGORY"), '') is null then null
      when regexp_replace(btrim("CATEGORY"), '\.0+$', '') ~ '^-?\d+$'
        then regexp_replace(btrim("CATEGORY"), '\.0+$', '')::integer
      else null
    end as category,

    nullif(btrim("FIRST_NAME"), '') as first_name,

    case
      when nullif(btrim("QTY"), '') is null then null
      when regexp_replace(btrim("QTY"), '\.0+$', '') ~ '^-?\d+$'
        then regexp_replace(btrim("QTY"), '\.0+$', '')::integer
      else null
    end as qty,

    case
      when nullif(replace(btrim("PROD_TOTAL"), ',', ''), '') is null then null
      when replace(btrim("PROD_TOTAL"), ',', '') ~ '^-?\d+(\.\d+)?$'
        then replace(btrim("PROD_TOTAL"), ',', '')::numeric(12,2)
      else null
    end as prod_total,

    nullif(btrim("PROD_ID"), '') as prod_id,

    case
      when nullif(btrim("DATE"), '') is null then null
      else btrim("DATE")::timestamptz
    end as sale_datetime,

    nullif(btrim("SOURCE_DOCUMENT_NUMBER"), '') as source_document_number,
    nullif(btrim("DESCRIPTION"), '') as description,
    nullif(btrim("WHOLE_NAME"), '') as whole_name,
    nullif(btrim("PRODUCT_TYPE"), '') as product_type,
    nullif(btrim("PARENT_PROD_TYPE"), '') as parent_prod_type,

    nullif(btrim("PROD_CAT"), '') as prod_cat,

    nullif(btrim("NAME"), '') as staff_work_name,
    p_import_batch_id::text as raw_location,
    row_number() over (),
    jsonb_build_object(
      'CATEGORY', "CATEGORY",
      'FIRST_NAME', "FIRST_NAME",
      'QTY', "QTY",
      'PROD_TOTAL', "PROD_TOTAL",
      'PROD_ID', "PROD_ID",
      'DATE', "DATE",
      'SOURCE_DOCUMENT_NUMBER', "SOURCE_DOCUMENT_NUMBER",
      'DESCRIPTION', "DESCRIPTION",
      'WHOLE_NAME', "WHOLE_NAME",
      'PRODUCT_TYPE', "PRODUCT_TYPE",
      'PARENT_PROD_TYPE', "PARENT_PROD_TYPE",
      'PROD_CAT', "PROD_CAT",
      'NAME', "NAME"
    )
  from public.stg_salesdailysheets;

  get diagnostics v_count = row_count;

  update public.sales_import_batches
  set row_count = v_count,
      updated_at = now()
  where id = p_import_batch_id;

  return v_count;
end;
$_$;


ALTER FUNCTION "public"."load_staged_sales_rows_to_raw"("p_import_batch_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalise_customer_name"("p_raw" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE PARALLEL SAFE
    SET "search_path" TO 'pg_catalog', 'public'
    AS $_$
  SELECT NULLIF(
    -- 4. collapse whitespace + trim + lowercase
    lower(
      btrim(
        regexp_replace(
          -- 3. strip standalone trailing A / B / C (case-insensitive)
          regexp_replace(
            -- 2. truncate from first standalone numeric suffix onward.
            --    A "standalone numeric suffix" is a run of digits
            --    preceded by whitespace and either at end-of-string
            --    or followed by whitespace. The replacement keeps
            --    everything up to (but not including) the leading
            --    whitespace of that numeric run.
            regexp_replace(
              -- 1. truncate from first '(' onward
              split_part(p_raw, '(', 1),
              '\s+\d+(\s.*)?$',
              '',
              'g'
            ),
            '\s+[abcABC]\s*$',
            '',
            'g'
          ),
          '\s+',
          ' ',
          'g'
        )
      )
    ),
    ''
  );
$_$;


ALTER FUNCTION "public"."normalise_customer_name"("p_raw" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_guest_quote"("payload" "jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."save_guest_quote"("payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_quote_service"("payload" "jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
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
$$;


ALTER FUNCTION "public"."save_quote_service"("payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_auth_users"("p_search" "text" DEFAULT NULL::"text") RETURNS TABLE("user_id" "uuid", "email" "text", "created_at" timestamp with time zone, "last_sign_in_at" timestamp with time zone)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
    AS $$
  SELECT
    u.id AS user_id,
    COALESCE(u.email::text, '') AS email,
    u.created_at,
    u.last_sign_in_at
  FROM auth.users AS u
  WHERE (SELECT private.user_has_elevated_access())
    AND COALESCE(u.email, '') <> ''
    AND NOT EXISTS (
      SELECT 1
      FROM public.staff_member_user_access AS m
      WHERE m.user_id = u.id
    )
    AND (
      p_search IS NULL
      OR length(trim(p_search)) = 0
      OR u.email::text ILIKE '%' || trim(p_search) || '%'
    )
  ORDER BY u.email
  LIMIT 100;
$$;


ALTER FUNCTION "public"."search_auth_users"("p_search" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_staff_members"("p_search" "text" DEFAULT NULL::"text") RETURNS TABLE("staff_member_id" "uuid", "display_name" "text", "full_name" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select
    s.id as staff_member_id,
    s.display_name,
    s.full_name
  from public.staff_members s
  where (select private.user_has_elevated_access())
    and coalesce(s.is_active, true) = true
    and (
      p_search is null
      or length(trim(p_search)) = 0
      or coalesce(s.display_name, '') ilike '%' || trim(p_search) || '%'
      or coalesce(s.full_name, '') ilike '%' || trim(p_search) || '%'
    )
  order by coalesce(s.full_name, s.display_name)
  limit 100
$$;


ALTER FUNCTION "public"."search_staff_members"("p_search" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text", "p_location_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'storage', 'auth', 'extensions', 'private', 'pg_temp'
    AS $$
DECLARE
  v_path text := trim(p_storage_path);
  v_uid uuid := auth.uid();
  v_batch_id uuid := gen_random_uuid();
  v_bucket_id text;
  v_found boolean;
  v_edge_url text;
  v_secret text;
  v_sql jsonb;
  v_out jsonb;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'not authenticated';
  END IF;

  IF NOT (SELECT private.user_has_elevated_access()) THEN
    RAISE EXCEPTION 'not authorized';
  END IF;

  IF v_path IS NULL OR v_path = '' THEN
    RAISE EXCEPTION 'p_storage_path is required';
  END IF;

  IF p_location_id IS NULL THEN
    RAISE EXCEPTION 'p_location_id is required';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.locations l
    WHERE l.id = p_location_id
      AND l.is_active
  ) THEN
    RAISE EXCEPTION 'invalid or inactive p_location_id';
  END IF;

  IF v_path ~ '\.\.' OR substring(v_path from 1 for 1) = '/' THEN
    RAISE EXCEPTION 'invalid storage path';
  END IF;

  IF v_path NOT LIKE 'incoming/%' THEN
    RAISE EXCEPTION 'storage path must start with incoming/';
  END IF;

  SELECT b.id INTO v_bucket_id
  FROM storage.buckets b
  WHERE b.name = 'sales-daily-sheets'
  LIMIT 1;

  IF v_bucket_id IS NULL THEN
    RAISE EXCEPTION 'storage bucket sales-daily-sheets is not configured';
  END IF;

  SELECT EXISTS (
    SELECT 1
    FROM storage.objects o
    WHERE o.bucket_id = v_bucket_id
      AND o.name = v_path
  ) INTO v_found;

  IF NOT v_found THEN
    RAISE EXCEPTION 'object not found: % (upload to bucket sales-daily-sheets first)', v_path;
  END IF;

  SELECT
    nullif(trim(c.sales_daily_import_edge_url), ''),
    nullif(trim(c.internal_import_secret), '')
  INTO v_edge_url, v_secret
  FROM private.sales_daily_sheets_import_config c
  WHERE c.id = 1;

  IF v_edge_url IS NOT NULL AND v_secret IS NOT NULL THEN
    INSERT INTO public.sales_daily_sheets_import_batches (
      id,
      storage_path,
      status,
      message,
      rows_staged,
      rows_loaded,
      error_message,
      created_by,
      selected_location_id
    )
    VALUES (
      v_batch_id,
      v_path,
      'queued',
      'Queued — processing runs in Edge (client)',
      NULL,
      NULL,
      NULL,
      v_uid,
      p_location_id
    );

    RETURN jsonb_build_object(
      'success', true,
      'status', 'queued',
      'batch_id', v_batch_id,
      'storage_path', v_path,
      'message', 'Batch queued. Call the sales-daily-sheets-import Edge Function to process.',
      'rows_staged', NULL,
      'rows_loaded', NULL,
      'error_message', NULL
    );

  ELSIF to_regprocedure('public.sales_daily_sheets_import_pipeline_sql(uuid,text)') IS NOT NULL THEN
    INSERT INTO public.sales_daily_sheets_import_batches (
      id,
      storage_path,
      status,
      message,
      rows_staged,
      rows_loaded,
      error_message,
      created_by,
      selected_location_id
    )
    VALUES (
      v_batch_id,
      v_path,
      'processing',
      NULL,
      NULL,
      NULL,
      NULL,
      v_uid,
      p_location_id
    );

    BEGIN
      v_sql := public.sales_daily_sheets_import_pipeline_sql(v_batch_id, v_path);
      UPDATE public.sales_daily_sheets_staged_rows r
      SET location_id = p_location_id
      WHERE r.batch_id = v_batch_id;
      v_out := coalesce(v_sql, '{}'::jsonb);
      IF NOT (v_out ? 'error_message') THEN
        v_out := v_out || jsonb_build_object('error_message', NULL);
      END IF;
      RETURN v_out;
    EXCEPTION
      WHEN OTHERS THEN
        UPDATE public.sales_daily_sheets_import_batches b
        SET
          status = 'failed',
          error_message = left(SQLERRM, 4000),
          message = 'Import failed (sales_daily_sheets_import_pipeline_sql)'
        WHERE b.id = v_batch_id;

        RETURN jsonb_build_object(
          'success', false,
          'message', SQLERRM,
          'batch_id', v_batch_id,
          'storage_path', v_path,
          'rows_staged', NULL,
          'rows_loaded', NULL,
          'status', 'failed',
          'error_message', SQLERRM
        );
    END;

  ELSE
    INSERT INTO public.sales_daily_sheets_import_batches (
      id,
      storage_path,
      status,
      message,
      rows_staged,
      rows_loaded,
      error_message,
      created_by,
      selected_location_id
    )
    VALUES (
      v_batch_id,
      v_path,
      'failed',
      'Import not configured',
      NULL,
      NULL,
      'Populate private.sales_daily_sheets_import_config (id=1) with Edge URL and secret, or define public.sales_daily_sheets_import_pipeline_sql(uuid,text).',
      v_uid,
      p_location_id
    );

    RETURN jsonb_build_object(
      'success', false,
      'message', 'Import pipeline not configured on the database',
      'batch_id', v_batch_id,
      'storage_path', v_path,
      'rows_staged', NULL,
      'rows_loaded', NULL,
      'status', 'failed',
      'error_message',
      'Configure private.sales_daily_sheets_import_config, or provide sales_daily_sheets_import_pipeline_sql.'
    );
  END IF;
END;
$$;


ALTER FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text", "p_location_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_access_mapping"("p_mapping_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) RETURNS "public"."staff_member_user_access"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  v_row public.staff_member_user_access;
begin
  if not private.user_can_manage_access_mappings() then
    raise exception 'Access denied';
  end if;

  update public.staff_member_user_access
  set
    staff_member_id = p_staff_member_id,
    access_role = lower(trim(p_access_role)),
    is_active = p_is_active,
    updated_at = now()
  where id = p_mapping_id
  returning *
  into v_row;

  if v_row.id is null then
    raise exception 'Mapping not found';
  end if;

  return v_row;
end;
$$;


ALTER FUNCTION "public"."update_access_mapping"("p_mapping_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "private"."sales_daily_sheets_import_config" (
    "id" integer NOT NULL,
    "sales_daily_import_edge_url" "text",
    "internal_import_secret" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sales_daily_sheets_import_config_id_check" CHECK (("id" = 1))
);


ALTER TABLE "private"."sales_daily_sheets_import_config" OWNER TO "postgres";


COMMENT ON TABLE "private"."sales_daily_sheets_import_config" IS 'Singleton (id=1) runtime config for trigger_sales_daily_sheets_import. Secrets are stored for server-side use only; restrict access.';



CREATE TABLE IF NOT EXISTS "public"."kpi_definitions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "display_name" "text" NOT NULL,
    "description" "text",
    "goal_group" "text" NOT NULL,
    "value_type" "text" NOT NULL,
    "unit" "text",
    "direction" "text" DEFAULT 'higher_is_better'::"text" NOT NULL,
    "period_grain" "text" DEFAULT 'monthly'::"text" NOT NULL,
    "source_type" "text" NOT NULL,
    "supports_mtd_pacing" boolean DEFAULT false NOT NULL,
    "mtd_proration_method" "text",
    "live_rpc_name" "text",
    "finalisation_rpc_name" "text",
    "default_level_type" "text" DEFAULT 'business'::"text" NOT NULL,
    "visibility_tier" "text" DEFAULT 'admin'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kpi_definitions_code_not_blank" CHECK (("btrim"("code") <> ''::"text")),
    CONSTRAINT "kpi_definitions_default_level_type_check" CHECK (("default_level_type" = ANY (ARRAY['business'::"text", 'location'::"text", 'staff'::"text"]))),
    CONSTRAINT "kpi_definitions_direction_check" CHECK (("direction" = ANY (ARRAY['higher_is_better'::"text", 'lower_is_better'::"text"]))),
    CONSTRAINT "kpi_definitions_goal_group_check" CHECK (("goal_group" = ANY (ARRAY['financial'::"text", 'operational'::"text", 'client'::"text", 'staff'::"text", 'retention'::"text", 'stock'::"text"]))),
    CONSTRAINT "kpi_definitions_mtd_proration_check" CHECK ((("mtd_proration_method" IS NULL) OR ("mtd_proration_method" = ANY (ARRAY['linear_calendar_days'::"text", 'none'::"text"])))),
    CONSTRAINT "kpi_definitions_mtd_requires_method" CHECK (((NOT "supports_mtd_pacing") OR ("mtd_proration_method" IS NOT NULL))),
    CONSTRAINT "kpi_definitions_period_grain_check" CHECK (("period_grain" = ANY (ARRAY['monthly'::"text", 'quarterly'::"text", 'rolling_6m'::"text", 'rolling_12m'::"text", 'snapshot'::"text"]))),
    CONSTRAINT "kpi_definitions_source_type_check" CHECK (("source_type" = ANY (ARRAY['live_calculated'::"text", 'calculated_monthly'::"text", 'uploaded'::"text", 'manual'::"text", 'hybrid'::"text"]))),
    CONSTRAINT "kpi_definitions_value_type_check" CHECK (("value_type" = ANY (ARRAY['currency'::"text", 'count'::"text", 'percent'::"text", 'ratio'::"text", 'minutes'::"text", 'number'::"text"]))),
    CONSTRAINT "kpi_definitions_visibility_tier_check" CHECK (("visibility_tier" = ANY (ARRAY['stylist'::"text", 'manager'::"text", 'admin'::"text"])))
);


ALTER TABLE "public"."kpi_definitions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kpi_manual_inputs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "kpi_definition_id" "uuid" NOT NULL,
    "period_grain" "text" NOT NULL,
    "period_start" "date" NOT NULL,
    "period_end" "date" NOT NULL,
    "scope_type" "text" NOT NULL,
    "location_id" "uuid",
    "staff_member_id" "uuid",
    "value" numeric(18,4) NOT NULL,
    "value_numerator" numeric(18,4),
    "value_denominator" numeric(18,4),
    "notes" "text",
    "entered_by" "uuid",
    "entered_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kpi_manual_inputs_period_grain_check" CHECK (("period_grain" = ANY (ARRAY['monthly'::"text", 'quarterly'::"text", 'rolling_6m'::"text", 'rolling_12m'::"text", 'snapshot'::"text"]))),
    CONSTRAINT "kpi_manual_inputs_period_order_check" CHECK (("period_end" >= "period_start")),
    CONSTRAINT "kpi_manual_inputs_scope_consistency" CHECK (((("scope_type" = 'business'::"text") AND ("location_id" IS NULL) AND ("staff_member_id" IS NULL)) OR (("scope_type" = 'location'::"text") AND ("location_id" IS NOT NULL) AND ("staff_member_id" IS NULL)) OR (("scope_type" = 'staff'::"text") AND ("staff_member_id" IS NOT NULL)))),
    CONSTRAINT "kpi_manual_inputs_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['business'::"text", 'location'::"text", 'staff'::"text"])))
);


ALTER TABLE "public"."kpi_manual_inputs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kpi_monthly_values" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "kpi_definition_id" "uuid" NOT NULL,
    "period_grain" "text" NOT NULL,
    "period_start" "date" NOT NULL,
    "period_end" "date" NOT NULL,
    "scope_type" "text" NOT NULL,
    "location_id" "uuid",
    "staff_member_id" "uuid",
    "value" numeric(18,4) NOT NULL,
    "value_numerator" numeric(18,4),
    "value_denominator" numeric(18,4),
    "source_type" "text" NOT NULL,
    "status" "text" DEFAULT 'final'::"text" NOT NULL,
    "finalised_at" timestamp with time zone,
    "finalised_by" "uuid",
    "upload_batch_id" "uuid",
    "manual_input_id" "uuid",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kpi_monthly_values_period_grain_check" CHECK (("period_grain" = ANY (ARRAY['monthly'::"text", 'quarterly'::"text", 'rolling_6m'::"text", 'rolling_12m'::"text", 'snapshot'::"text"]))),
    CONSTRAINT "kpi_monthly_values_period_order_check" CHECK (("period_end" >= "period_start")),
    CONSTRAINT "kpi_monthly_values_scope_consistency" CHECK (((("scope_type" = 'business'::"text") AND ("location_id" IS NULL) AND ("staff_member_id" IS NULL)) OR (("scope_type" = 'location'::"text") AND ("location_id" IS NOT NULL) AND ("staff_member_id" IS NULL)) OR (("scope_type" = 'staff'::"text") AND ("staff_member_id" IS NOT NULL)))),
    CONSTRAINT "kpi_monthly_values_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['business'::"text", 'location'::"text", 'staff'::"text"]))),
    CONSTRAINT "kpi_monthly_values_source_type_check" CHECK (("source_type" = ANY (ARRAY['calculated_monthly'::"text", 'uploaded'::"text", 'manual'::"text", 'hybrid'::"text", 'live_snapshot'::"text"]))),
    CONSTRAINT "kpi_monthly_values_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'final'::"text", 'superseded'::"text"])))
);


ALTER TABLE "public"."kpi_monthly_values" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kpi_targets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "kpi_definition_id" "uuid" NOT NULL,
    "period_grain" "text" NOT NULL,
    "period_start" "date" NOT NULL,
    "period_end" "date" NOT NULL,
    "scope_type" "text" NOT NULL,
    "location_id" "uuid",
    "staff_member_id" "uuid",
    "target_value" numeric(18,4) NOT NULL,
    "stretch_value" numeric(18,4),
    "mtd_proration_method" "text",
    "notes" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kpi_targets_mtd_proration_check" CHECK ((("mtd_proration_method" IS NULL) OR ("mtd_proration_method" = ANY (ARRAY['linear_calendar_days'::"text", 'none'::"text"])))),
    CONSTRAINT "kpi_targets_period_grain_check" CHECK (("period_grain" = ANY (ARRAY['monthly'::"text", 'quarterly'::"text", 'rolling_6m'::"text", 'rolling_12m'::"text", 'snapshot'::"text"]))),
    CONSTRAINT "kpi_targets_period_order_check" CHECK (("period_end" >= "period_start")),
    CONSTRAINT "kpi_targets_scope_consistency" CHECK (((("scope_type" = 'business'::"text") AND ("location_id" IS NULL) AND ("staff_member_id" IS NULL)) OR (("scope_type" = 'location'::"text") AND ("location_id" IS NOT NULL) AND ("staff_member_id" IS NULL)) OR (("scope_type" = 'staff'::"text") AND ("staff_member_id" IS NOT NULL)))),
    CONSTRAINT "kpi_targets_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['business'::"text", 'location'::"text", 'staff'::"text"])))
);


ALTER TABLE "public"."kpi_targets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kpi_upload_batches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "kpi_definition_id" "uuid",
    "location_id" "uuid",
    "file_name" "text",
    "file_storage_path" "text",
    "uploaded_by" "uuid",
    "uploaded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "period_grain" "text",
    "period_start" "date",
    "period_end" "date",
    "row_count" integer DEFAULT 0 NOT NULL,
    "accepted_count" integer DEFAULT 0 NOT NULL,
    "rejected_count" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kpi_upload_batches_counts_check" CHECK ((("row_count" >= 0) AND ("accepted_count" >= 0) AND ("rejected_count" >= 0) AND (("accepted_count" + "rejected_count") <= "row_count"))),
    CONSTRAINT "kpi_upload_batches_period_grain_check" CHECK ((("period_grain" IS NULL) OR ("period_grain" = ANY (ARRAY['monthly'::"text", 'quarterly'::"text", 'rolling_6m'::"text", 'rolling_12m'::"text", 'snapshot'::"text"])))),
    CONSTRAINT "kpi_upload_batches_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'processing'::"text", 'accepted'::"text", 'rejected'::"text", 'partially_accepted'::"text"])))
);


ALTER TABLE "public"."kpi_upload_batches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."kpi_upload_rows" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "upload_batch_id" "uuid" NOT NULL,
    "kpi_definition_id" "uuid" NOT NULL,
    "period_grain" "text" NOT NULL,
    "period_start" "date" NOT NULL,
    "period_end" "date" NOT NULL,
    "scope_type" "text" NOT NULL,
    "staff_member_id" "uuid",
    "value" numeric(18,4),
    "raw_row" "jsonb",
    "row_status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "error_message" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "kpi_upload_rows_period_grain_check" CHECK (("period_grain" = ANY (ARRAY['monthly'::"text", 'quarterly'::"text", 'rolling_6m'::"text", 'rolling_12m'::"text", 'snapshot'::"text"]))),
    CONSTRAINT "kpi_upload_rows_period_order_check" CHECK (("period_end" >= "period_start")),
    CONSTRAINT "kpi_upload_rows_row_status_check" CHECK (("row_status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'rejected'::"text"]))),
    CONSTRAINT "kpi_upload_rows_scope_consistency" CHECK (((("scope_type" = ANY (ARRAY['business'::"text", 'location'::"text"])) AND ("staff_member_id" IS NULL)) OR (("scope_type" = 'staff'::"text") AND ("staff_member_id" IS NOT NULL)))),
    CONSTRAINT "kpi_upload_rows_scope_type_check" CHECK (("scope_type" = ANY (ARRAY['business'::"text", 'location'::"text", 'staff'::"text"]))),
    CONSTRAINT "kpi_upload_rows_value_required_when_accepted" CHECK ((("row_status" <> 'accepted'::"text") OR ("value" IS NOT NULL)))
);


ALTER TABLE "public"."kpi_upload_rows" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."quote_sections" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "summary_label" "text" NOT NULL,
    "display_order" integer NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "section_help_text" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "quote_sections_display_order_min" CHECK (("display_order" >= 1)),
    CONSTRAINT "quote_sections_name_not_blank" CHECK (("length"("btrim"("name")) > 0)),
    CONSTRAINT "quote_sections_summary_label_not_blank" CHECK (("length"("btrim"("summary_label")) > 0))
);


ALTER TABLE "public"."quote_sections" OWNER TO "postgres";


COMMENT ON TABLE "public"."quote_sections" IS 'Ordered list of Guest Quote sections. Archive via active = false.';



COMMENT ON COLUMN "public"."quote_sections"."summary_label" IS 'Label used when grouping sections on the saved quote summary footer. Duplicates are intentional.';



CREATE TABLE IF NOT EXISTS "public"."quote_service_options" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "service_id" "uuid" NOT NULL,
    "label" "text" NOT NULL,
    "value_key" "text" NOT NULL,
    "display_order" integer NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "price" numeric(10,2),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "quote_service_options_display_order_min" CHECK (("display_order" >= 1)),
    CONSTRAINT "quote_service_options_label_not_blank" CHECK (("length"("btrim"("label")) > 0)),
    CONSTRAINT "quote_service_options_price_non_negative" CHECK ((("price" IS NULL) OR ("price" >= (0)::numeric))),
    CONSTRAINT "quote_service_options_value_key_format" CHECK (("value_key" ~ '^[a-z0-9_]+$'::"text"))
);


ALTER TABLE "public"."quote_service_options" OWNER TO "postgres";


COMMENT ON TABLE "public"."quote_service_options" IS 'Ordered options for services with option-based input or option-based pricing.';



CREATE TABLE IF NOT EXISTS "public"."quote_service_role_prices" (
    "service_id" "uuid" NOT NULL,
    "role" "text" NOT NULL,
    "price" numeric(10,2) NOT NULL,
    CONSTRAINT "quote_service_role_prices_non_negative" CHECK (("price" >= (0)::numeric)),
    CONSTRAINT "quote_service_role_prices_role_allowed" CHECK (("role" = ANY (ARRAY['EMERGING'::"text", 'SENIOR'::"text", 'DIRECTOR'::"text", 'MASTER'::"text"])))
);


ALTER TABLE "public"."quote_service_role_prices" OWNER TO "postgres";


COMMENT ON TABLE "public"."quote_service_role_prices" IS 'Per-role prices for role_price services. One row per (service_id, role).';



CREATE TABLE IF NOT EXISTS "public"."quote_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "section_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "internal_key" "text",
    "active" boolean DEFAULT true NOT NULL,
    "display_order" integer NOT NULL,
    "help_text" "text",
    "summary_label_override" "text",
    "input_type" "text" NOT NULL,
    "pricing_type" "text" NOT NULL,
    "visible_roles" "text"[] DEFAULT ARRAY[]::"text"[] NOT NULL,
    "fixed_price" numeric(10,2),
    "numeric_config" "jsonb",
    "extra_unit_config" "jsonb",
    "special_extra_config" "jsonb",
    "link_to_base_service_id" "uuid",
    "include_in_quote_summary" boolean DEFAULT true NOT NULL,
    "summary_group_override" "text",
    "admin_notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "quote_services_display_order_min" CHECK (("display_order" >= 1)),
    CONSTRAINT "quote_services_fixed_price_non_negative" CHECK ((("fixed_price" IS NULL) OR ("fixed_price" >= (0)::numeric))),
    CONSTRAINT "quote_services_input_type_allowed" CHECK (("input_type" = ANY (ARRAY['checkbox'::"text", 'role_radio'::"text", 'option_radio'::"text", 'dropdown'::"text", 'numeric_input'::"text", 'extra_units'::"text", 'special_extra_product'::"text"]))),
    CONSTRAINT "quote_services_internal_key_format" CHECK ((("internal_key" IS NULL) OR ("internal_key" ~ '^[a-z0-9_]+$'::"text"))),
    CONSTRAINT "quote_services_link_to_base_not_self" CHECK ((("link_to_base_service_id" IS NULL) OR ("link_to_base_service_id" <> "id"))),
    CONSTRAINT "quote_services_name_not_blank" CHECK (("length"("btrim"("name")) > 0)),
    CONSTRAINT "quote_services_pricing_config_matches" CHECK (((("pricing_type" = 'fixed_price'::"text") AND ("fixed_price" IS NOT NULL) AND ("numeric_config" IS NULL) AND ("extra_unit_config" IS NULL) AND ("special_extra_config" IS NULL)) OR (("pricing_type" = 'role_price'::"text") AND ("fixed_price" IS NULL) AND ("numeric_config" IS NULL) AND ("extra_unit_config" IS NULL) AND ("special_extra_config" IS NULL)) OR (("pricing_type" = 'option_price'::"text") AND ("fixed_price" IS NULL) AND ("numeric_config" IS NULL) AND ("extra_unit_config" IS NULL) AND ("special_extra_config" IS NULL)) OR (("pricing_type" = 'numeric_multiplier'::"text") AND ("fixed_price" IS NULL) AND ("numeric_config" IS NOT NULL) AND ("extra_unit_config" IS NULL) AND ("special_extra_config" IS NULL)) OR (("pricing_type" = 'extra_unit_price'::"text") AND ("fixed_price" IS NULL) AND ("numeric_config" IS NULL) AND ("extra_unit_config" IS NOT NULL) AND ("special_extra_config" IS NULL)) OR (("pricing_type" = 'special_extra_product'::"text") AND ("fixed_price" IS NULL) AND ("numeric_config" IS NULL) AND ("extra_unit_config" IS NULL) AND ("special_extra_config" IS NOT NULL)))),
    CONSTRAINT "quote_services_pricing_type_allowed" CHECK (("pricing_type" = ANY (ARRAY['fixed_price'::"text", 'role_price'::"text", 'option_price'::"text", 'numeric_multiplier'::"text", 'extra_unit_price'::"text", 'special_extra_product'::"text"]))),
    CONSTRAINT "quote_services_role_based_visible_roles_required" CHECK (((NOT (("input_type" = 'role_radio'::"text") OR ("pricing_type" = 'role_price'::"text"))) OR ("cardinality"("visible_roles") >= 1))),
    CONSTRAINT "quote_services_visible_roles_allowed" CHECK (("visible_roles" <@ ARRAY['EMERGING'::"text", 'SENIOR'::"text", 'DIRECTOR'::"text", 'MASTER'::"text"]))
);


ALTER TABLE "public"."quote_services" OWNER TO "postgres";


COMMENT ON TABLE "public"."quote_services" IS 'Services inside a quote section. Pricing config lives on the matching sidecar column per pricing_type.';



COMMENT ON COLUMN "public"."quote_services"."visible_roles" IS 'Roles shown in stylist quote UI. Subset of (EMERGING, SENIOR, DIRECTOR, MASTER).';



COMMENT ON COLUMN "public"."quote_services"."numeric_config" IS 'JSONB sidecar; populated when pricing_type = numeric_multiplier. Shape is validated by the app layer.';



COMMENT ON COLUMN "public"."quote_services"."extra_unit_config" IS 'JSONB sidecar; populated when pricing_type = extra_unit_price. Shape is validated by the app layer.';



COMMENT ON COLUMN "public"."quote_services"."special_extra_config" IS 'JSONB sidecar; populated when pricing_type = special_extra_product. Shape is validated by the app layer.';



COMMENT ON COLUMN "public"."quote_services"."link_to_base_service_id" IS 'Optional linkage for extra-unit services to their base service (lifted out of JSONB so it can be FK-enforced).';



CREATE TABLE IF NOT EXISTS "public"."quote_settings" (
    "id" smallint DEFAULT 1 NOT NULL,
    "green_fee_amount" numeric(10,2) DEFAULT 0 NOT NULL,
    "notes_enabled" boolean DEFAULT true NOT NULL,
    "guest_name_required" boolean DEFAULT false NOT NULL,
    "quote_page_title" "text" DEFAULT 'Guest Quote'::"text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "quote_settings_green_fee_non_negative" CHECK (("green_fee_amount" >= (0)::numeric)),
    CONSTRAINT "quote_settings_page_title_not_blank" CHECK (("length"("btrim"("quote_page_title")) > 0)),
    CONSTRAINT "quote_settings_singleton" CHECK (("id" = 1))
);


ALTER TABLE "public"."quote_settings" OWNER TO "postgres";


COMMENT ON TABLE "public"."quote_settings" IS 'Global Guest Quote settings. Single row (id = 1) enforced by CHECK.';



CREATE TABLE IF NOT EXISTS "public"."raw_sales_import_rows" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "import_batch_id" "uuid" NOT NULL,
    "category" integer,
    "first_name" "text",
    "qty" integer,
    "prod_total" numeric(12,2),
    "prod_id" "text",
    "sale_datetime" timestamp with time zone,
    "source_document_number" "text",
    "description" "text",
    "whole_name" "text",
    "product_type" "text",
    "parent_prod_type" "text",
    "prod_cat" "text",
    "staff_work_name" "text",
    "raw_location" "text",
    "row_num" integer,
    "raw_payload" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."raw_sales_import_rows" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sales_daily_sheets_import_batches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "storage_path" "text" NOT NULL,
    "status" "text" DEFAULT 'registered'::"text" NOT NULL,
    "message" "text",
    "rows_staged" integer,
    "rows_loaded" integer,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "error_message" "text",
    "payroll_import_batch_id" "uuid",
    "selected_location_id" "uuid"
);


ALTER TABLE "public"."sales_daily_sheets_import_batches" OWNER TO "postgres";


COMMENT ON TABLE "public"."sales_daily_sheets_import_batches" IS 'Audit log for Sales Daily Sheets uploads; RPC trigger_sales_daily_sheets_import inserts rows.';



COMMENT ON COLUMN "public"."sales_daily_sheets_import_batches"."error_message" IS 'Failure detail; also returned as error_message in trigger_sales_daily_sheets_import JSON.';



COMMENT ON COLUMN "public"."sales_daily_sheets_import_batches"."payroll_import_batch_id" IS 'sales_import_batches row created for this sheet batch; used for idempotent reload and traceability.';



COMMENT ON COLUMN "public"."sales_daily_sheets_import_batches"."selected_location_id" IS 'Location chosen in Admin Imports; applied to staged rows and payroll merge.';



CREATE TABLE IF NOT EXISTS "public"."sales_daily_sheets_staged_rows" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "batch_id" "uuid" NOT NULL,
    "line_number" integer NOT NULL,
    "invoice" "text",
    "sale_date" "text",
    "pay_week_start" "date",
    "pay_week_end" "date",
    "pay_date" "date",
    "customer_name" "text",
    "product_service_name" "text",
    "quantity" numeric,
    "price_ex_gst" numeric,
    "derived_staff_paid_display_name" "text",
    "actual_commission_amount" numeric,
    "assistant_commission_amount" numeric,
    "payroll_status" "text",
    "stylist_visible_note" "text",
    "location_id" "uuid",
    "extras" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sales_daily_sheets_staged_rows" OWNER TO "postgres";


COMMENT ON TABLE "public"."sales_daily_sheets_staged_rows" IS 'Parsed CSV lines per import batch; populated by Edge Function or sales_daily_sheets_import_pipeline_sql.';



COMMENT ON COLUMN "public"."sales_daily_sheets_staged_rows"."batch_id" IS 'Logical link to sales_daily_sheets_import_batches.id. No FK: Edge runs outside the RPC transaction that inserts the batch.';



CREATE TABLE IF NOT EXISTS "public"."sales_import_batches" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "source_name" "text" NOT NULL,
    "source_file_name" "text",
    "location_id" "uuid" NOT NULL,
    "imported_by_user_id" "uuid",
    "imported_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "notes" "text",
    "row_count" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "sales_import_batches_source_name_not_blank" CHECK (("btrim"("source_name") <> ''::"text")),
    CONSTRAINT "sales_import_batches_status_valid" CHECK (("status" = ANY (ARRAY['pending'::"text", 'processed'::"text", 'failed'::"text"])))
);


ALTER TABLE "public"."sales_import_batches" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."saved_quote_line_options" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "saved_quote_line_id" "uuid" NOT NULL,
    "service_option_id" "uuid",
    "option_label_snapshot" "text" NOT NULL,
    "option_value_key_snapshot" "text" NOT NULL,
    "option_price_snapshot" numeric(10,2),
    CONSTRAINT "saved_quote_line_options_label_not_blank" CHECK (("length"("btrim"("option_label_snapshot")) > 0)),
    CONSTRAINT "saved_quote_line_options_price_non_negative" CHECK ((("option_price_snapshot" IS NULL) OR ("option_price_snapshot" >= (0)::numeric))),
    CONSTRAINT "saved_quote_line_options_value_key_not_blank" CHECK (("length"("btrim"("option_value_key_snapshot")) > 0))
);


ALTER TABLE "public"."saved_quote_line_options" OWNER TO "postgres";


COMMENT ON TABLE "public"."saved_quote_line_options" IS 'Selected option rows per saved quote line. Label/value/price are snapshot columns; service_option_id is traceability only.';



CREATE TABLE IF NOT EXISTS "public"."saved_quote_lines" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "saved_quote_id" "uuid" NOT NULL,
    "line_order" integer NOT NULL,
    "service_id" "uuid",
    "section_id" "uuid",
    "section_name_snapshot" "text" NOT NULL,
    "section_summary_label_snapshot" "text" NOT NULL,
    "service_name_snapshot" "text" NOT NULL,
    "service_internal_key_snapshot" "text",
    "input_type_snapshot" "text" NOT NULL,
    "pricing_type_snapshot" "text" NOT NULL,
    "selected_role" "text",
    "numeric_quantity" numeric(12,2),
    "numeric_unit_label_snapshot" "text",
    "extra_units_selected" integer,
    "special_extra_rows_snapshot" "jsonb",
    "unit_price_snapshot" numeric(10,2),
    "line_total" numeric(12,2) NOT NULL,
    "include_in_summary_snapshot" boolean DEFAULT true NOT NULL,
    "summary_group_snapshot" "text" NOT NULL,
    "config_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "saved_quote_lines_extra_units_non_negative" CHECK ((("extra_units_selected" IS NULL) OR ("extra_units_selected" >= 0))),
    CONSTRAINT "saved_quote_lines_input_type_allowed" CHECK (("input_type_snapshot" = ANY (ARRAY['checkbox'::"text", 'role_radio'::"text", 'option_radio'::"text", 'dropdown'::"text", 'numeric_input'::"text", 'extra_units'::"text", 'special_extra_product'::"text"]))),
    CONSTRAINT "saved_quote_lines_line_order_min" CHECK (("line_order" >= 1)),
    CONSTRAINT "saved_quote_lines_line_total_non_negative" CHECK (("line_total" >= (0)::numeric)),
    CONSTRAINT "saved_quote_lines_pricing_type_allowed" CHECK (("pricing_type_snapshot" = ANY (ARRAY['fixed_price'::"text", 'role_price'::"text", 'option_price'::"text", 'numeric_multiplier'::"text", 'extra_unit_price'::"text", 'special_extra_product'::"text"]))),
    CONSTRAINT "saved_quote_lines_section_name_not_blank" CHECK (("length"("btrim"("section_name_snapshot")) > 0)),
    CONSTRAINT "saved_quote_lines_section_summary_label_not_blank" CHECK (("length"("btrim"("section_summary_label_snapshot")) > 0)),
    CONSTRAINT "saved_quote_lines_selected_role_allowed" CHECK ((("selected_role" IS NULL) OR ("selected_role" = ANY (ARRAY['EMERGING'::"text", 'SENIOR'::"text", 'DIRECTOR'::"text", 'MASTER'::"text"])))),
    CONSTRAINT "saved_quote_lines_service_name_not_blank" CHECK (("length"("btrim"("service_name_snapshot")) > 0)),
    CONSTRAINT "saved_quote_lines_summary_group_not_blank" CHECK (("length"("btrim"("summary_group_snapshot")) > 0)),
    CONSTRAINT "saved_quote_lines_unit_price_non_negative" CHECK ((("unit_price_snapshot" IS NULL) OR ("unit_price_snapshot" >= (0)::numeric)))
);


ALTER TABLE "public"."saved_quote_lines" OWNER TO "postgres";


COMMENT ON TABLE "public"."saved_quote_lines" IS 'One row per selected service in a saved quote. Snapshot columns capture service/section state at save time; FKs are traceability only.';



COMMENT ON COLUMN "public"."saved_quote_lines"."config_snapshot" IS 'Full relevant pricing config blob at save time (role prices, numeric/extra_unit/special_extra configs, sibling options). Shape validated by app layer.';



CREATE TABLE IF NOT EXISTS "public"."saved_quote_section_totals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "saved_quote_id" "uuid" NOT NULL,
    "display_order" integer NOT NULL,
    "section_summary_label_snapshot" "text" NOT NULL,
    "section_name_snapshot" "text",
    "section_total" numeric(12,2) NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "saved_quote_section_totals_display_order_min" CHECK (("display_order" >= 1)),
    CONSTRAINT "saved_quote_section_totals_summary_label_not_blank" CHECK (("length"("btrim"("section_summary_label_snapshot")) > 0)),
    CONSTRAINT "saved_quote_section_totals_total_non_negative" CHECK (("section_total" >= (0)::numeric))
);


ALTER TABLE "public"."saved_quote_section_totals" OWNER TO "postgres";


COMMENT ON TABLE "public"."saved_quote_section_totals" IS 'Snapshot section totals per saved quote, in the display order shown on the saved quote summary footer.';



CREATE TABLE IF NOT EXISTS "public"."saved_quotes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "guest_name" "text",
    "stylist_user_id" "uuid" NOT NULL,
    "stylist_staff_member_id" "uuid",
    "stylist_display_name" "text" NOT NULL,
    "quote_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "notes" "text",
    "grand_total" numeric(12,2) NOT NULL,
    "green_fee_applied" numeric(10,2) NOT NULL,
    "settings_snapshot" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "saved_quotes_grand_total_non_negative" CHECK (("grand_total" >= (0)::numeric)),
    CONSTRAINT "saved_quotes_green_fee_non_negative" CHECK (("green_fee_applied" >= (0)::numeric)),
    CONSTRAINT "saved_quotes_stylist_display_name_not_blank" CHECK (("length"("btrim"("stylist_display_name")) > 0))
);


ALTER TABLE "public"."saved_quotes" OWNER TO "postgres";


COMMENT ON TABLE "public"."saved_quotes" IS 'Header row per saved guest quote. Snapshot-first: settings_snapshot and stylist_display_name preserve state at save time.';



COMMENT ON COLUMN "public"."saved_quotes"."settings_snapshot" IS 'Full QuoteSettings at save time (green fee, page title, toggles). Shape validated by app layer.';



CREATE TABLE IF NOT EXISTS "public"."staff_capacity_monthly" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "staff_member_id" "uuid" NOT NULL,
    "period_start" "date" NOT NULL,
    "period_end" "date" NOT NULL,
    "capacity_minutes" integer NOT NULL,
    "working_days" integer,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "staff_capacity_monthly_minutes_nonneg" CHECK (("capacity_minutes" >= 0)),
    CONSTRAINT "staff_capacity_monthly_period_order_check" CHECK (("period_end" >= "period_start")),
    CONSTRAINT "staff_capacity_monthly_working_days_nonneg" CHECK ((("working_days" IS NULL) OR ("working_days" >= 0)))
);


ALTER TABLE "public"."staff_capacity_monthly" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stg_dimproducts" (
    "product_description" "text",
    "system_type" "text",
    "product_type" "text"
);


ALTER TABLE "public"."stg_dimproducts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stg_dimremunerationplans" (
    "remuneration_plan" "text",
    "retail_product" "text",
    "professional_product" "text",
    "service" "text",
    "can_use_assistants" "text",
    "toner_with_other_service" "text",
    "extensions_product" "text",
    "extensions_service" "text",
    "conditions" "text",
    "staff_on_this_plan" "text"
);


ALTER TABLE "public"."stg_dimremunerationplans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stg_dimstaff" (
    "active" "text",
    "address_1" "text",
    "address_2" "text",
    "city" "text",
    "company_name" "text",
    "dob" "text",
    "end_date" "text",
    "first_name" "text",
    "fte_equiv" "text",
    "gst_number" "text",
    "ird_number" "text",
    "kitomba_name" "text",
    "last_name" "text",
    "primary_role" "text",
    "rem_plan" "text",
    "secondary_roles" "text",
    "start_date" "text"
);


ALTER TABLE "public"."stg_dimstaff" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."stg_salesdailysheets" (
    "CATEGORY" "text",
    "FIRST_NAME" "text",
    "QTY" "text",
    "PROD_TOTAL" "text",
    "PROD_ID" "text",
    "DATE" "text",
    "SOURCE_DOCUMENT_NUMBER" "text",
    "DESCRIPTION" "text",
    "WHOLE_NAME" "text",
    "PRODUCT_TYPE" "text",
    "PARENT_PROD_TYPE" "text",
    "PROD_CAT" "text",
    "NAME" "text"
);


ALTER TABLE "public"."stg_salesdailysheets" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_admin_payroll_summary" AS
 SELECT "month_start",
    "location_id",
    "derived_staff_paid_id",
    "derived_staff_paid_display_name",
    "derived_staff_paid_full_name",
    "derived_staff_paid_remuneration_plan",
    "count"(*) AS "line_count",
    "count"(*) FILTER (WHERE ("payroll_status" = 'payable'::"text")) AS "payable_line_count",
    "count"(*) FILTER (WHERE ("payroll_status" = 'expected_no_commission'::"text")) AS "expected_no_commission_line_count",
    "count"(*) FILTER (WHERE ("payroll_status" = 'zero_value_commission_row'::"text")) AS "zero_value_line_count",
    "count"(*) FILTER (WHERE ("requires_review" = true)) AS "review_line_count",
    "round"("sum"(COALESCE("price_ex_gst", (0)::numeric)), 2) AS "total_sales_ex_gst",
    "round"("sum"(COALESCE("actual_commission_amt_ex_gst", (0)::numeric)), 2) AS "total_actual_commission_ex_gst",
    "round"("sum"(COALESCE("theoretical_commission_amt_ex_gst", (0)::numeric)), 2) AS "total_theoretical_commission_ex_gst",
    "round"("sum"(COALESCE("assistant_commission_amt_ex_gst", (0)::numeric)), 2) AS "total_assistant_commission_ex_gst"
   FROM "public"."v_admin_payroll_lines"
  GROUP BY "month_start", "location_id", "derived_staff_paid_id", "derived_staff_paid_display_name", "derived_staff_paid_full_name", "derived_staff_paid_remuneration_plan";


ALTER VIEW "public"."v_admin_payroll_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_admin_payroll_summary_by_location" AS
 SELECT "s"."month_start",
    "s"."location_id",
    "l"."code" AS "location_code",
    "l"."name" AS "location_name",
    "count"(*) AS "stylist_summary_row_count",
    "sum"("s"."line_count") AS "total_line_count",
    "sum"("s"."payable_line_count") AS "total_payable_line_count",
    "sum"("s"."expected_no_commission_line_count") AS "total_expected_no_commission_line_count",
    "sum"("s"."zero_value_line_count") AS "total_zero_value_line_count",
    "sum"("s"."review_line_count") AS "total_review_line_count",
    "round"("sum"("s"."total_sales_ex_gst"), 2) AS "total_sales_ex_gst",
    "round"("sum"("s"."total_actual_commission_ex_gst"), 2) AS "total_actual_commission_ex_gst",
    "round"("sum"("s"."total_theoretical_commission_ex_gst"), 2) AS "total_theoretical_commission_ex_gst",
    "round"("sum"("s"."total_assistant_commission_ex_gst"), 2) AS "total_assistant_commission_ex_gst",
        CASE
            WHEN ("sum"("s"."total_sales_ex_gst") <> (0)::numeric) THEN "round"(("sum"("s"."total_actual_commission_ex_gst") / "sum"("s"."total_sales_ex_gst")), 4)
            ELSE NULL::numeric
        END AS "actual_commission_pct_of_sales",
        CASE
            WHEN ("sum"("s"."total_sales_ex_gst") <> (0)::numeric) THEN "round"(("sum"("s"."total_theoretical_commission_ex_gst") / "sum"("s"."total_sales_ex_gst")), 4)
            ELSE NULL::numeric
        END AS "theoretical_commission_pct_of_sales"
   FROM ("public"."v_admin_payroll_summary" "s"
     LEFT JOIN "public"."locations" "l" ON (("l"."id" = "s"."location_id")))
  GROUP BY "s"."month_start", "s"."location_id", "l"."code", "l"."name";


ALTER VIEW "public"."v_admin_payroll_summary_by_location" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_admin_payroll_summary_by_stylist" AS
 SELECT "s"."month_start",
    "s"."location_id",
    "l"."code" AS "location_code",
    "l"."name" AS "location_name",
    "s"."derived_staff_paid_id",
    "s"."derived_staff_paid_display_name",
    "s"."derived_staff_paid_full_name",
    "s"."derived_staff_paid_remuneration_plan",
    "s"."line_count",
    "s"."payable_line_count",
    "s"."expected_no_commission_line_count",
    "s"."zero_value_line_count",
    "s"."review_line_count",
    "s"."total_sales_ex_gst",
    "s"."total_actual_commission_ex_gst",
    "s"."total_theoretical_commission_ex_gst",
    "s"."total_assistant_commission_ex_gst",
        CASE
            WHEN ("s"."total_sales_ex_gst" <> (0)::numeric) THEN "round"(("s"."total_actual_commission_ex_gst" / "s"."total_sales_ex_gst"), 4)
            ELSE NULL::numeric
        END AS "actual_commission_pct_of_sales",
        CASE
            WHEN ("s"."total_sales_ex_gst" <> (0)::numeric) THEN "round"(("s"."total_theoretical_commission_ex_gst" / "s"."total_sales_ex_gst"), 4)
            ELSE NULL::numeric
        END AS "theoretical_commission_pct_of_sales"
   FROM ("public"."v_admin_payroll_summary" "s"
     LEFT JOIN "public"."locations" "l" ON (("l"."id" = "s"."location_id")));


ALTER VIEW "public"."v_admin_payroll_summary_by_stylist" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_admin_user_access_overview" AS
 SELECT "a"."id",
    "a"."user_id",
    "u"."email",
    "a"."staff_member_id",
    "s"."display_name" AS "staff_display_name",
    "s"."full_name" AS "staff_full_name",
    "a"."access_role",
    "a"."is_active",
    "a"."created_at",
    "a"."updated_at"
   FROM (("public"."staff_member_user_access" "a"
     LEFT JOIN "auth"."users" "u" ON (("u"."id" = "a"."user_id")))
     LEFT JOIN "public"."staff_members" "s" ON (("s"."id" = "a"."staff_member_id")));


ALTER VIEW "public"."v_admin_user_access_overview" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_sales_transactions_enriched" AS
 WITH "base" AS (
         SELECT "st"."id",
            "st"."import_batch_id",
            "st"."raw_row_id",
            "st"."location_id",
            "st"."invoice",
            "st"."customer_name",
            "st"."sale_datetime",
            "st"."sale_date",
            "st"."day_name",
            "st"."month_start",
            "st"."month_num",
            "st"."product_service_name",
            "st"."product_master_id",
            "st"."raw_product_type",
            "st"."product_type_actual",
            "st"."product_type_short",
            "st"."commission_product_service",
            "st"."quantity",
            "st"."price_ex_gst",
            "st"."price_incl_gst",
            "st"."price_gst_component",
            "st"."staff_work_name",
            "st"."staff_work_id",
            "st"."staff_work_type",
            "st"."staff_paid_name",
            "st"."staff_paid_id",
            "st"."staff_paid_type",
            "st"."staff_commission_name",
            "st"."staff_commission_id",
            "st"."staff_commission_type",
            "st"."assistant_usage_alert" AS "assistant_usage_alert_source",
            "st"."staff_work_is_staff_paid",
            "st"."invoice_header",
            "st"."product_header",
            "sw"."display_name" AS "staff_work_display_name",
            "sw"."full_name" AS "staff_work_full_name",
            "sw"."primary_role" AS "staff_work_primary_role",
            "sw"."remuneration_plan" AS "staff_work_remuneration_plan",
            "sw"."employment_type" AS "staff_work_employment_type",
            "sw"."is_active" AS "staff_work_is_active",
            "sp"."display_name" AS "staff_paid_display_name",
            "sp"."full_name" AS "staff_paid_full_name",
            "sp"."primary_role" AS "staff_paid_primary_role",
            "sp"."remuneration_plan" AS "staff_paid_remuneration_plan",
            "sp"."employment_type" AS "staff_paid_employment_type",
            "sp"."is_active" AS "staff_paid_is_active",
            "sc"."display_name" AS "staff_commission_display_name",
            "sc"."full_name" AS "staff_commission_full_name",
            "sc"."primary_role" AS "staff_commission_primary_role",
            "sc"."remuneration_plan" AS "staff_commission_remuneration_plan",
            "sc"."employment_type" AS "staff_commission_employment_type",
            "sc"."is_active" AS "staff_commission_is_active",
            "st"."created_at",
            "st"."updated_at"
           FROM ((("public"."sales_transactions" "st"
             LEFT JOIN LATERAL ( SELECT "sm"."id",
                    "sm"."full_name",
                    "sm"."display_name",
                    "sm"."primary_role",
                    "sm"."remuneration_plan",
                    "sm"."employment_type",
                    "sm"."is_active",
                    "sm"."first_seen_sale_date",
                    "sm"."last_seen_sale_date",
                    "sm"."notes",
                    "sm"."created_at",
                    "sm"."updated_at",
                    "sm"."secondary_roles",
                    "sm"."fte",
                    "sm"."employment_start_date",
                    "sm"."employment_end_date",
                    "sm"."contractor_company_name",
                    "sm"."contractor_gst_registered",
                    "sm"."contractor_ird_number",
                    "sm"."contractor_street_address",
                    "sm"."contractor_suburb",
                    "sm"."contractor_city_postcode"
                   FROM "public"."staff_members" "sm"
                  WHERE ((("st"."staff_work_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_work_id")) OR (("st"."staff_work_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text") IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "st"."staff_work_name")) = "lower"(TRIM(BOTH FROM "sm"."display_name"))) AND ("sm"."is_active" = true)))
                  ORDER BY
                        CASE
                            WHEN (("st"."staff_work_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_work_id")) THEN 0
                            ELSE 1
                        END
                 LIMIT 1) "sw" ON (true))
             LEFT JOIN LATERAL ( SELECT "sm"."id",
                    "sm"."full_name",
                    "sm"."display_name",
                    "sm"."primary_role",
                    "sm"."remuneration_plan",
                    "sm"."employment_type",
                    "sm"."is_active",
                    "sm"."first_seen_sale_date",
                    "sm"."last_seen_sale_date",
                    "sm"."notes",
                    "sm"."created_at",
                    "sm"."updated_at",
                    "sm"."secondary_roles",
                    "sm"."fte",
                    "sm"."employment_start_date",
                    "sm"."employment_end_date",
                    "sm"."contractor_company_name",
                    "sm"."contractor_gst_registered",
                    "sm"."contractor_ird_number",
                    "sm"."contractor_street_address",
                    "sm"."contractor_suburb",
                    "sm"."contractor_city_postcode"
                   FROM "public"."staff_members" "sm"
                  WHERE ((("st"."staff_paid_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_paid_id")) OR (("st"."staff_paid_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_paid_name", ''::"text")), ''::"text") IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "st"."staff_paid_name")) = "lower"(TRIM(BOTH FROM "sm"."display_name"))) AND ("sm"."is_active" = true)))
                  ORDER BY
                        CASE
                            WHEN (("st"."staff_paid_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_paid_id")) THEN 0
                            ELSE 1
                        END
                 LIMIT 1) "sp" ON (true))
             LEFT JOIN LATERAL ( SELECT "sm"."id",
                    "sm"."full_name",
                    "sm"."display_name",
                    "sm"."primary_role",
                    "sm"."remuneration_plan",
                    "sm"."employment_type",
                    "sm"."is_active",
                    "sm"."first_seen_sale_date",
                    "sm"."last_seen_sale_date",
                    "sm"."notes",
                    "sm"."created_at",
                    "sm"."updated_at",
                    "sm"."secondary_roles",
                    "sm"."fte",
                    "sm"."employment_start_date",
                    "sm"."employment_end_date",
                    "sm"."contractor_company_name",
                    "sm"."contractor_gst_registered",
                    "sm"."contractor_ird_number",
                    "sm"."contractor_street_address",
                    "sm"."contractor_suburb",
                    "sm"."contractor_city_postcode"
                   FROM "public"."staff_members" "sm"
                  WHERE ((("st"."staff_commission_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_commission_id")) OR (("st"."staff_commission_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text") IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "st"."staff_commission_name")) = "lower"(TRIM(BOTH FROM "sm"."display_name"))) AND ("sm"."is_active" = true)))
                  ORDER BY
                        CASE
                            WHEN (("st"."staff_commission_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_commission_id")) THEN 0
                            ELSE 1
                        END
                 LIMIT 1) "sc" ON (true))
        ), "classified" AS (
         SELECT "b"."id",
            "b"."import_batch_id",
            "b"."raw_row_id",
            "b"."location_id",
            "b"."invoice",
            "b"."customer_name",
            "b"."sale_datetime",
            "b"."sale_date",
            "b"."day_name",
            "b"."month_start",
            "b"."month_num",
            "b"."product_service_name",
            "b"."product_master_id",
            "b"."raw_product_type",
            "b"."product_type_actual",
            "b"."product_type_short",
            "b"."commission_product_service",
            "b"."quantity",
            "b"."price_ex_gst",
            "b"."price_incl_gst",
            "b"."price_gst_component",
            "b"."staff_work_name",
            "b"."staff_work_id",
            "b"."staff_work_type",
            "b"."staff_paid_name",
            "b"."staff_paid_id",
            "b"."staff_paid_type",
            "b"."staff_commission_name",
            "b"."staff_commission_id",
            "b"."staff_commission_type",
            "b"."assistant_usage_alert_source",
            "b"."staff_work_is_staff_paid",
            "b"."invoice_header",
            "b"."product_header",
            "b"."staff_work_display_name",
            "b"."staff_work_full_name",
            "b"."staff_work_primary_role",
            "b"."staff_work_remuneration_plan",
            "b"."staff_work_employment_type",
            "b"."staff_work_is_active",
            "b"."staff_paid_display_name",
            "b"."staff_paid_full_name",
            "b"."staff_paid_primary_role",
            "b"."staff_paid_remuneration_plan",
            "b"."staff_paid_employment_type",
            "b"."staff_paid_is_active",
            "b"."staff_commission_display_name",
            "b"."staff_commission_full_name",
            "b"."staff_commission_primary_role",
            "b"."staff_commission_remuneration_plan",
            "b"."staff_commission_employment_type",
            "b"."staff_commission_is_active",
            "b"."created_at",
            "b"."updated_at",
                CASE
                    WHEN (COALESCE("lower"(TRIM(BOTH FROM "b"."commission_product_service")), ''::"text") ~~ '%service%'::"text") THEN 'service'::"text"
                    WHEN (COALESCE("lower"(TRIM(BOTH FROM "b"."commission_product_service")), ''::"text") ~~ '%retail%'::"text") THEN 'retail'::"text"
                    WHEN (COALESCE("lower"(TRIM(BOTH FROM "b"."product_type_actual")), ''::"text") ~~ '%service%'::"text") THEN 'service'::"text"
                    WHEN (COALESCE("lower"(TRIM(BOTH FROM "b"."product_type_short")), ''::"text") ~~ '%service%'::"text") THEN 'service'::"text"
                    WHEN (COALESCE("lower"(TRIM(BOTH FROM "b"."raw_product_type")), ''::"text") ~~ '%service%'::"text") THEN 'service'::"text"
                    ELSE 'other'::"text"
                END AS "transaction_class",
                CASE
                    WHEN (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_work_primary_role")), ''::"text") = 'assistant'::"text") THEN true
                    ELSE false
                END AS "is_assistant_work",
                CASE
                    WHEN (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_paid_primary_role")), ''::"text") = 'assistant'::"text") THEN true
                    ELSE false
                END AS "is_assistant_paid",
                CASE
                    WHEN (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_commission_primary_role")), ''::"text") = 'assistant'::"text") THEN true
                    ELSE false
                END AS "is_assistant_commission",
                CASE
                    WHEN (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_work_remuneration_plan")), ''::"text") = 'wage'::"text") THEN true
                    ELSE false
                END AS "is_waged_work_staff",
                CASE
                    WHEN (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_paid_remuneration_plan")), ''::"text") = 'wage'::"text") THEN true
                    ELSE false
                END AS "is_waged_paid_staff",
                CASE
                    WHEN (("b"."staff_work_id" IS NOT NULL) AND ("b"."staff_paid_id" IS NOT NULL) AND ("b"."staff_work_id" <> "b"."staff_paid_id")) THEN true
                    ELSE false
                END AS "work_paid_mismatch",
                CASE
                    WHEN (("b"."staff_work_id" IS NOT NULL) AND ("b"."staff_commission_id" IS NOT NULL) AND ("b"."staff_work_id" <> "b"."staff_commission_id")) THEN true
                    ELSE false
                END AS "work_commission_mismatch",
                CASE
                    WHEN (("b"."staff_work_id" IS NOT NULL) AND ("b"."staff_paid_id" IS NOT NULL) AND (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_work_primary_role")), ''::"text") = 'assistant'::"text") AND (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_work_remuneration_plan")), ''::"text") = 'wage'::"text") AND ("b"."staff_work_id" <> "b"."staff_paid_id")) THEN true
                    ELSE false
                END AS "assistant_redirect_candidate",
                CASE
                    WHEN (("b"."staff_work_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("b"."staff_work_name", ''::"text")), ''::"text") IS NOT NULL)) THEN 'unmatched_work_staff'::"text"
                    WHEN (("b"."staff_paid_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("b"."staff_paid_name", ''::"text")), ''::"text") IS NOT NULL)) THEN 'unmatched_paid_staff'::"text"
                    WHEN (("b"."staff_commission_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("b"."staff_commission_name", ''::"text")), ''::"text") IS NOT NULL)) THEN 'unmatched_commission_staff'::"text"
                    WHEN (("b"."staff_work_id" IS NOT NULL) AND ("b"."staff_paid_id" IS NOT NULL) AND (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_work_primary_role")), ''::"text") = 'assistant'::"text") AND (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_work_remuneration_plan")), ''::"text") = 'wage'::"text") AND ("b"."staff_work_id" <> "b"."staff_paid_id")) THEN 'assistant_work_redirect_candidate'::"text"
                    WHEN (("b"."staff_work_id" IS NOT NULL) AND ("b"."staff_paid_id" IS NOT NULL) AND ("b"."staff_work_id" <> "b"."staff_paid_id")) THEN 'work_paid_mismatch'::"text"
                    ELSE NULL::"text"
                END AS "review_flag"
           FROM "base" "b"
        )
 SELECT "id",
    "import_batch_id",
    "raw_row_id",
    "location_id",
    "invoice",
    "customer_name",
    "sale_datetime",
    "sale_date",
    "day_name",
    "month_start",
    "month_num",
    "product_service_name",
    "product_master_id",
    "raw_product_type",
    "product_type_actual",
    "product_type_short",
    "commission_product_service",
    "quantity",
    "price_ex_gst",
    "price_incl_gst",
    "price_gst_component",
    "staff_work_name",
    "staff_work_id",
    "staff_work_type",
    "staff_paid_name",
    "staff_paid_id",
    "staff_paid_type",
    "staff_commission_name",
    "staff_commission_id",
    "staff_commission_type",
    "assistant_usage_alert_source",
    "staff_work_is_staff_paid",
    "invoice_header",
    "product_header",
    "staff_work_display_name",
    "staff_work_full_name",
    "staff_work_primary_role",
    "staff_work_remuneration_plan",
    "staff_work_employment_type",
    "staff_work_is_active",
    "staff_paid_display_name",
    "staff_paid_full_name",
    "staff_paid_primary_role",
    "staff_paid_remuneration_plan",
    "staff_paid_employment_type",
    "staff_paid_is_active",
    "staff_commission_display_name",
    "staff_commission_full_name",
    "staff_commission_primary_role",
    "staff_commission_remuneration_plan",
    "staff_commission_employment_type",
    "staff_commission_is_active",
    "created_at",
    "updated_at",
    "transaction_class",
    "is_assistant_work",
    "is_assistant_paid",
    "is_assistant_commission",
    "is_waged_work_staff",
    "is_waged_paid_staff",
    "work_paid_mismatch",
    "work_commission_mismatch",
    "assistant_redirect_candidate",
    "review_flag",
        CASE
            WHEN "assistant_redirect_candidate" THEN "staff_paid_id"
            WHEN ("staff_commission_id" IS NOT NULL) THEN "staff_commission_id"
            WHEN ("staff_paid_id" IS NOT NULL) THEN "staff_paid_id"
            ELSE "staff_work_id"
        END AS "commission_owner_candidate_id",
        CASE
            WHEN "assistant_redirect_candidate" THEN "staff_paid_display_name"
            WHEN ("staff_commission_id" IS NOT NULL) THEN "staff_commission_display_name"
            WHEN ("staff_paid_id" IS NOT NULL) THEN "staff_paid_display_name"
            ELSE "staff_work_display_name"
        END AS "commission_owner_candidate_name",
        CASE
            WHEN "assistant_redirect_candidate" THEN 'assistant_work_redirected_to_paid_staff'::"text"
            WHEN ("staff_commission_id" IS NOT NULL) THEN 'explicit_commission_staff'::"text"
            WHEN ("staff_paid_id" IS NOT NULL) THEN 'paid_staff_fallback'::"text"
            WHEN ("staff_work_id" IS NOT NULL) THEN 'work_staff_fallback'::"text"
            ELSE 'unassigned'::"text"
        END AS "commission_owner_rule"
   FROM "classified" "c";


ALTER VIEW "public"."v_sales_transactions_enriched" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_stylist_commission_lines_secure" AS
 SELECT "id",
    "import_batch_id",
    "raw_row_id",
    "location_id",
    "invoice",
    "sale_datetime",
    "sale_date",
    "day_name",
    "month_start",
    "month_num",
    "customer_name",
    "product_service_name",
    "product_type_actual",
    "product_type_short",
    "commission_product_service",
    "commission_category_final",
    "quantity",
    "price_ex_gst",
    "price_incl_gst",
    "derived_staff_paid_id",
    "derived_staff_paid_display_name",
    "derived_staff_paid_full_name",
    "actual_commission_rate",
    "actual_commission_amt_ex_gst",
    "assistant_commission_amt_ex_gst",
    "payroll_status",
        CASE
            WHEN ("payroll_status" = 'expected_no_commission'::"text") THEN "calculation_alert"
            WHEN ("payroll_status" = 'zero_value_commission_row'::"text") THEN 'zero_commission_row'::"text"
            ELSE NULL::"text"
        END AS "stylist_visible_note"
   FROM "public"."v_admin_payroll_lines";


ALTER VIEW "public"."v_stylist_commission_lines_secure" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_stylist_commission_lines_access_scoped" AS
 SELECT "a"."user_id",
    "l"."id",
    "l"."import_batch_id",
    "l"."raw_row_id",
    "l"."location_id",
    "l"."invoice",
    "l"."sale_datetime",
    "l"."sale_date",
    "l"."day_name",
    "l"."month_start",
    "l"."month_num",
    "l"."customer_name",
    "l"."product_service_name",
    "l"."product_type_actual",
    "l"."product_type_short",
    "l"."commission_product_service",
    "l"."commission_category_final",
    "l"."quantity",
    "l"."price_ex_gst",
    "l"."price_incl_gst",
    "l"."derived_staff_paid_id",
    "l"."derived_staff_paid_display_name",
    "l"."derived_staff_paid_full_name",
    "l"."actual_commission_rate",
    "l"."actual_commission_amt_ex_gst",
    "l"."assistant_commission_amt_ex_gst",
    "l"."payroll_status",
    "l"."stylist_visible_note",
    "a"."access_role"
   FROM ("public"."v_stylist_commission_lines_secure" "l"
     JOIN "public"."staff_member_user_access" "a" ON ((("a"."is_active" = true) AND ((("a"."access_role" = ANY (ARRAY['stylist'::"text", 'assistant'::"text"])) AND ("a"."staff_member_id" = "l"."derived_staff_paid_id")) OR ("a"."access_role" = ANY (ARRAY['manager'::"text", 'admin'::"text"]))))));


ALTER VIEW "public"."v_stylist_commission_lines_access_scoped" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_stylist_commission_lines_final" AS
 SELECT "user_id",
    "id",
    "import_batch_id",
    "raw_row_id",
    "location_id",
    "invoice",
    "sale_datetime",
    "sale_date",
    "day_name",
    "month_start",
    "month_num",
    "customer_name",
    "product_service_name",
    "product_type_actual",
    "product_type_short",
    "commission_product_service",
    "commission_category_final",
    "quantity",
    "price_ex_gst",
    "price_incl_gst",
    "derived_staff_paid_id",
    "derived_staff_paid_display_name",
    "derived_staff_paid_full_name",
    "actual_commission_rate",
    "actual_commission_amt_ex_gst",
    "assistant_commission_amt_ex_gst",
    "payroll_status",
    "stylist_visible_note",
    "access_role"
   FROM "public"."v_stylist_commission_lines_access_scoped"
  WHERE (("derived_staff_paid_id" IS NOT NULL) AND (COALESCE("lower"(TRIM(BOTH FROM "derived_staff_paid_display_name")), ''::"text") <> 'internal'::"text"));


ALTER VIEW "public"."v_stylist_commission_lines_final" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_stylist_commission_summary_secure" AS
 SELECT "month_start",
    "location_id",
    "derived_staff_paid_id",
    "derived_staff_paid_display_name",
    "derived_staff_paid_full_name",
    "count"(*) AS "line_count",
    "count"(*) FILTER (WHERE ("payroll_status" = 'payable'::"text")) AS "payable_line_count",
    "count"(*) FILTER (WHERE ("payroll_status" = 'expected_no_commission'::"text")) AS "expected_no_commission_line_count",
    "count"(*) FILTER (WHERE ("payroll_status" = 'zero_value_commission_row'::"text")) AS "zero_value_line_count",
    "round"("sum"(COALESCE("price_ex_gst", (0)::numeric)), 2) AS "total_sales_ex_gst",
    "round"("sum"(COALESCE("actual_commission_amt_ex_gst", (0)::numeric)), 2) AS "total_actual_commission_ex_gst",
    "round"("sum"(COALESCE("assistant_commission_amt_ex_gst", (0)::numeric)), 2) AS "total_assistant_commission_ex_gst"
   FROM "public"."v_stylist_commission_lines_secure"
  GROUP BY "month_start", "location_id", "derived_staff_paid_id", "derived_staff_paid_display_name", "derived_staff_paid_full_name";


ALTER VIEW "public"."v_stylist_commission_summary_secure" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_stylist_commission_summary_self_service" AS
 SELECT "month_start",
    "location_id",
    "derived_staff_paid_id",
    "derived_staff_paid_display_name",
    "derived_staff_paid_full_name",
    "line_count",
    "payable_line_count",
    "expected_no_commission_line_count",
    "zero_value_line_count",
    "total_sales_ex_gst",
    "total_actual_commission_ex_gst",
    "total_assistant_commission_ex_gst"
   FROM "public"."v_stylist_commission_summary_secure"
  WHERE (COALESCE("lower"(TRIM(BOTH FROM "derived_staff_paid_display_name")), ''::"text") <> 'internal'::"text");


ALTER VIEW "public"."v_stylist_commission_summary_self_service" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_stylist_commission_summary_access_scoped" AS
 SELECT "a"."user_id",
    "s"."month_start",
    "s"."location_id",
    "s"."derived_staff_paid_id",
    "s"."derived_staff_paid_display_name",
    "s"."derived_staff_paid_full_name",
    "s"."line_count",
    "s"."payable_line_count",
    "s"."expected_no_commission_line_count",
    "s"."zero_value_line_count",
    "s"."total_sales_ex_gst",
    "s"."total_actual_commission_ex_gst",
    "s"."total_assistant_commission_ex_gst",
    "a"."access_role"
   FROM ("public"."v_stylist_commission_summary_self_service" "s"
     JOIN "public"."staff_member_user_access" "a" ON ((("a"."is_active" = true) AND ((("a"."access_role" = ANY (ARRAY['stylist'::"text", 'assistant'::"text"])) AND ("a"."staff_member_id" = "s"."derived_staff_paid_id")) OR ("a"."access_role" = ANY (ARRAY['manager'::"text", 'admin'::"text"]))))));


ALTER VIEW "public"."v_stylist_commission_summary_access_scoped" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."v_stylist_commission_summary_final" AS
 SELECT "user_id",
    "month_start",
    "location_id",
    "derived_staff_paid_id",
    "derived_staff_paid_display_name",
    "derived_staff_paid_full_name",
    "line_count",
    "payable_line_count",
    "expected_no_commission_line_count",
    "zero_value_line_count",
    "total_sales_ex_gst",
    "total_actual_commission_ex_gst",
    "total_assistant_commission_ex_gst",
    "access_role"
   FROM "public"."v_stylist_commission_summary_access_scoped"
  WHERE (("derived_staff_paid_id" IS NOT NULL) AND (COALESCE("lower"(TRIM(BOTH FROM "derived_staff_paid_display_name")), ''::"text") <> 'internal'::"text"));


ALTER VIEW "public"."v_stylist_commission_summary_final" OWNER TO "postgres";


ALTER TABLE ONLY "private"."sales_daily_sheets_import_config"
    ADD CONSTRAINT "sales_daily_sheets_import_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."kpi_definitions"
    ADD CONSTRAINT "kpi_definitions_code_unique" UNIQUE ("code");



ALTER TABLE ONLY "public"."kpi_definitions"
    ADD CONSTRAINT "kpi_definitions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."kpi_manual_inputs"
    ADD CONSTRAINT "kpi_manual_inputs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."kpi_monthly_values"
    ADD CONSTRAINT "kpi_monthly_values_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."kpi_targets"
    ADD CONSTRAINT "kpi_targets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."kpi_upload_batches"
    ADD CONSTRAINT "kpi_upload_batches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."kpi_upload_rows"
    ADD CONSTRAINT "kpi_upload_rows_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "locations_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "locations_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."locations"
    ADD CONSTRAINT "locations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_master"
    ADD CONSTRAINT "product_master_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_master"
    ADD CONSTRAINT "product_master_product_description_key" UNIQUE ("product_description");



ALTER TABLE ONLY "public"."quote_sections"
    ADD CONSTRAINT "quote_sections_display_order_unique" UNIQUE ("display_order") DEFERRABLE;



ALTER TABLE ONLY "public"."quote_sections"
    ADD CONSTRAINT "quote_sections_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quote_service_options"
    ADD CONSTRAINT "quote_service_options_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quote_service_options"
    ADD CONSTRAINT "quote_service_options_service_order_unique" UNIQUE ("service_id", "display_order") DEFERRABLE;



ALTER TABLE ONLY "public"."quote_service_options"
    ADD CONSTRAINT "quote_service_options_service_value_key_unique" UNIQUE ("service_id", "value_key");



ALTER TABLE ONLY "public"."quote_service_role_prices"
    ADD CONSTRAINT "quote_service_role_prices_pkey" PRIMARY KEY ("service_id", "role");



ALTER TABLE ONLY "public"."quote_services"
    ADD CONSTRAINT "quote_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."quote_services"
    ADD CONSTRAINT "quote_services_section_order_unique" UNIQUE ("section_id", "display_order") DEFERRABLE;



ALTER TABLE ONLY "public"."quote_settings"
    ADD CONSTRAINT "quote_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."raw_sales_import_rows"
    ADD CONSTRAINT "raw_sales_import_rows_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."remuneration_plan_rates"
    ADD CONSTRAINT "remuneration_plan_rates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."remuneration_plan_rates"
    ADD CONSTRAINT "remuneration_plan_rates_unique" UNIQUE ("remuneration_plan_id", "commission_category");



ALTER TABLE ONLY "public"."remuneration_plans"
    ADD CONSTRAINT "remuneration_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."remuneration_plans"
    ADD CONSTRAINT "remuneration_plans_plan_name_key" UNIQUE ("plan_name");



ALTER TABLE ONLY "public"."sales_daily_sheets_import_batches"
    ADD CONSTRAINT "sales_daily_sheets_import_batches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_daily_sheets_staged_rows"
    ADD CONSTRAINT "sales_daily_sheets_staged_rows_batch_line" UNIQUE ("batch_id", "line_number");



ALTER TABLE ONLY "public"."sales_daily_sheets_staged_rows"
    ADD CONSTRAINT "sales_daily_sheets_staged_rows_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_import_batches"
    ADD CONSTRAINT "sales_import_batches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_transactions"
    ADD CONSTRAINT "sales_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_transactions"
    ADD CONSTRAINT "sales_transactions_raw_row_id_key" UNIQUE ("raw_row_id");



ALTER TABLE ONLY "public"."saved_quote_line_options"
    ADD CONSTRAINT "saved_quote_line_options_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."saved_quote_lines"
    ADD CONSTRAINT "saved_quote_lines_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."saved_quote_lines"
    ADD CONSTRAINT "saved_quote_lines_saved_quote_line_order_unique" UNIQUE ("saved_quote_id", "line_order");



ALTER TABLE ONLY "public"."saved_quote_section_totals"
    ADD CONSTRAINT "saved_quote_section_totals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."saved_quote_section_totals"
    ADD CONSTRAINT "saved_quote_section_totals_saved_quote_display_order_unique" UNIQUE ("saved_quote_id", "display_order");



ALTER TABLE ONLY "public"."saved_quotes"
    ADD CONSTRAINT "saved_quotes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."staff_capacity_monthly"
    ADD CONSTRAINT "staff_capacity_monthly_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."staff_member_user_access"
    ADD CONSTRAINT "staff_member_user_access_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."staff_members"
    ADD CONSTRAINT "staff_members_full_name_key" UNIQUE ("full_name");



ALTER TABLE ONLY "public"."staff_members"
    ADD CONSTRAINT "staff_members_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_quote_sections_active_display_order" ON "public"."quote_sections" USING "btree" ("active", "display_order");



CREATE INDEX "idx_quote_service_options_service_active_display_order" ON "public"."quote_service_options" USING "btree" ("service_id", "active", "display_order");



CREATE INDEX "idx_quote_services_section_active_display_order" ON "public"."quote_services" USING "btree" ("section_id", "active", "display_order");



CREATE INDEX "idx_raw_sales_import_rows_batch_id" ON "public"."raw_sales_import_rows" USING "btree" ("import_batch_id");



CREATE INDEX "idx_saved_quote_line_options_line" ON "public"."saved_quote_line_options" USING "btree" ("saved_quote_line_id");



CREATE INDEX "idx_saved_quote_line_options_option" ON "public"."saved_quote_line_options" USING "btree" ("service_option_id") WHERE ("service_option_id" IS NOT NULL);



CREATE INDEX "idx_saved_quote_lines_saved_quote_line_order" ON "public"."saved_quote_lines" USING "btree" ("saved_quote_id", "line_order");



CREATE INDEX "idx_saved_quote_lines_section" ON "public"."saved_quote_lines" USING "btree" ("section_id") WHERE ("section_id" IS NOT NULL);



CREATE INDEX "idx_saved_quote_lines_service" ON "public"."saved_quote_lines" USING "btree" ("service_id") WHERE ("service_id" IS NOT NULL);



CREATE INDEX "idx_saved_quote_section_totals_saved_quote_order" ON "public"."saved_quote_section_totals" USING "btree" ("saved_quote_id", "display_order");



CREATE INDEX "idx_saved_quotes_quote_date" ON "public"."saved_quotes" USING "btree" ("quote_date" DESC);



CREATE INDEX "idx_saved_quotes_stylist_user_created" ON "public"."saved_quotes" USING "btree" ("stylist_user_id", "created_at" DESC);



CREATE INDEX "ix_kpi_monthly_values_kpi_period" ON "public"."kpi_monthly_values" USING "btree" ("kpi_definition_id", "period_start" DESC);



CREATE INDEX "ix_kpi_monthly_values_location_period" ON "public"."kpi_monthly_values" USING "btree" ("location_id", "period_start" DESC) WHERE ("location_id" IS NOT NULL);



CREATE INDEX "ix_kpi_monthly_values_staff_period" ON "public"."kpi_monthly_values" USING "btree" ("staff_member_id", "period_start" DESC) WHERE ("staff_member_id" IS NOT NULL);



CREATE INDEX "ix_kpi_targets_kpi_period" ON "public"."kpi_targets" USING "btree" ("kpi_definition_id", "period_start" DESC);



CREATE INDEX "ix_kpi_upload_batches_location_uploaded_at" ON "public"."kpi_upload_batches" USING "btree" ("location_id", "uploaded_at" DESC) WHERE ("location_id" IS NOT NULL);



CREATE INDEX "ix_kpi_upload_batches_status_uploaded_at" ON "public"."kpi_upload_batches" USING "btree" ("status", "uploaded_at" DESC);



CREATE INDEX "ix_kpi_upload_rows_batch" ON "public"."kpi_upload_rows" USING "btree" ("upload_batch_id");



CREATE INDEX "ix_kpi_upload_rows_kpi_period" ON "public"."kpi_upload_rows" USING "btree" ("kpi_definition_id", "period_start");



CREATE UNIQUE INDEX "quote_services_internal_key_unique" ON "public"."quote_services" USING "btree" ("internal_key") WHERE ("internal_key" IS NOT NULL);



CREATE INDEX "sales_daily_sheets_import_batches_created_at_idx" ON "public"."sales_daily_sheets_import_batches" USING "btree" ("created_at" DESC);



CREATE INDEX "sales_daily_sheets_staged_rows_batch_id_idx" ON "public"."sales_daily_sheets_staged_rows" USING "btree" ("batch_id");



CREATE UNIQUE INDEX "ux_kpi_manual_inputs_scope" ON "public"."kpi_manual_inputs" USING "btree" ("kpi_definition_id", "period_grain", "period_start", "scope_type", COALESCE("location_id", '00000000-0000-0000-0000-000000000000'::"uuid"), COALESCE("staff_member_id", '00000000-0000-0000-0000-000000000000'::"uuid"));



CREATE UNIQUE INDEX "ux_kpi_monthly_values_final_scope" ON "public"."kpi_monthly_values" USING "btree" ("kpi_definition_id", "period_grain", "period_start", "scope_type", COALESCE("location_id", '00000000-0000-0000-0000-000000000000'::"uuid"), COALESCE("staff_member_id", '00000000-0000-0000-0000-000000000000'::"uuid")) WHERE ("status" = 'final'::"text");



CREATE UNIQUE INDEX "ux_kpi_targets_scope" ON "public"."kpi_targets" USING "btree" ("kpi_definition_id", "period_grain", "period_start", "scope_type", COALESCE("location_id", '00000000-0000-0000-0000-000000000000'::"uuid"), COALESCE("staff_member_id", '00000000-0000-0000-0000-000000000000'::"uuid"));



CREATE UNIQUE INDEX "ux_staff_capacity_monthly_staff_period" ON "public"."staff_capacity_monthly" USING "btree" ("staff_member_id", "period_start");



CREATE UNIQUE INDEX "ux_staff_member_user_access_user_staff_role" ON "public"."staff_member_user_access" USING "btree" ("user_id", COALESCE("staff_member_id", '00000000-0000-0000-0000-000000000000'::"uuid"), "access_role");



CREATE OR REPLACE TRIGGER "trg_kpi_definitions_updated_at" BEFORE UPDATE ON "public"."kpi_definitions" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_kpi_manual_inputs_updated_at" BEFORE UPDATE ON "public"."kpi_manual_inputs" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_kpi_monthly_values_updated_at" BEFORE UPDATE ON "public"."kpi_monthly_values" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_kpi_targets_updated_at" BEFORE UPDATE ON "public"."kpi_targets" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_kpi_upload_batches_updated_at" BEFORE UPDATE ON "public"."kpi_upload_batches" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_kpi_upload_rows_updated_at" BEFORE UPDATE ON "public"."kpi_upload_rows" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_locations_updated_at" BEFORE UPDATE ON "public"."locations" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_product_master_updated_at" BEFORE UPDATE ON "public"."product_master" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_quote_sections_block_delete_if_used" BEFORE DELETE ON "public"."quote_sections" FOR EACH ROW EXECUTE FUNCTION "private"."quote_sections_block_delete_if_used"();



CREATE OR REPLACE TRIGGER "trg_quote_sections_updated_at" BEFORE UPDATE ON "public"."quote_sections" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_quote_service_options_block_delete_if_used" BEFORE DELETE ON "public"."quote_service_options" FOR EACH ROW EXECUTE FUNCTION "private"."quote_service_options_block_delete_if_used"();



CREATE OR REPLACE TRIGGER "trg_quote_service_options_updated_at" BEFORE UPDATE ON "public"."quote_service_options" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE CONSTRAINT TRIGGER "trg_quote_service_options_validate" AFTER INSERT OR DELETE OR UPDATE ON "public"."quote_service_options" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "private"."quote_service_options_validate_row"();



CREATE CONSTRAINT TRIGGER "trg_quote_service_role_prices_validate" AFTER INSERT OR DELETE OR UPDATE ON "public"."quote_service_role_prices" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "private"."quote_service_role_prices_validate_row"();



CREATE OR REPLACE TRIGGER "trg_quote_services_block_delete_if_used" BEFORE DELETE ON "public"."quote_services" FOR EACH ROW EXECUTE FUNCTION "private"."quote_services_block_delete_if_used"();



CREATE OR REPLACE TRIGGER "trg_quote_services_updated_at" BEFORE UPDATE ON "public"."quote_services" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE CONSTRAINT TRIGGER "trg_quote_services_validate" AFTER INSERT OR UPDATE OF "input_type", "pricing_type", "visible_roles" ON "public"."quote_services" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "private"."quote_services_validate_row"();



CREATE OR REPLACE TRIGGER "trg_quote_settings_updated_at" BEFORE UPDATE ON "public"."quote_settings" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_raw_sales_import_rows_updated_at" BEFORE UPDATE ON "public"."raw_sales_import_rows" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_remuneration_plan_rates_updated_at" BEFORE UPDATE ON "public"."remuneration_plan_rates" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_remuneration_plans_updated_at" BEFORE UPDATE ON "public"."remuneration_plans" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_sales_import_batches_updated_at" BEFORE UPDATE ON "public"."sales_import_batches" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_saved_quotes_updated_at" BEFORE UPDATE ON "public"."saved_quotes" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_staff_capacity_monthly_updated_at" BEFORE UPDATE ON "public"."staff_capacity_monthly" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_staff_member_user_access_updated_at" BEFORE UPDATE ON "public"."staff_member_user_access" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_staff_members_updated_at" BEFORE UPDATE ON "public"."staff_members" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



ALTER TABLE ONLY "public"."kpi_manual_inputs"
    ADD CONSTRAINT "kpi_manual_inputs_entered_by_fkey" FOREIGN KEY ("entered_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."kpi_manual_inputs"
    ADD CONSTRAINT "kpi_manual_inputs_kpi_definition_id_fkey" FOREIGN KEY ("kpi_definition_id") REFERENCES "public"."kpi_definitions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_manual_inputs"
    ADD CONSTRAINT "kpi_manual_inputs_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_manual_inputs"
    ADD CONSTRAINT "kpi_manual_inputs_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "public"."staff_members"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_monthly_values"
    ADD CONSTRAINT "kpi_monthly_values_finalised_by_fkey" FOREIGN KEY ("finalised_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."kpi_monthly_values"
    ADD CONSTRAINT "kpi_monthly_values_kpi_definition_id_fkey" FOREIGN KEY ("kpi_definition_id") REFERENCES "public"."kpi_definitions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_monthly_values"
    ADD CONSTRAINT "kpi_monthly_values_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_monthly_values"
    ADD CONSTRAINT "kpi_monthly_values_manual_input_fkey" FOREIGN KEY ("manual_input_id") REFERENCES "public"."kpi_manual_inputs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."kpi_monthly_values"
    ADD CONSTRAINT "kpi_monthly_values_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "public"."staff_members"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_monthly_values"
    ADD CONSTRAINT "kpi_monthly_values_upload_batch_fkey" FOREIGN KEY ("upload_batch_id") REFERENCES "public"."kpi_upload_batches"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."kpi_targets"
    ADD CONSTRAINT "kpi_targets_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."kpi_targets"
    ADD CONSTRAINT "kpi_targets_kpi_definition_id_fkey" FOREIGN KEY ("kpi_definition_id") REFERENCES "public"."kpi_definitions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_targets"
    ADD CONSTRAINT "kpi_targets_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_targets"
    ADD CONSTRAINT "kpi_targets_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "public"."staff_members"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_upload_batches"
    ADD CONSTRAINT "kpi_upload_batches_kpi_definition_id_fkey" FOREIGN KEY ("kpi_definition_id") REFERENCES "public"."kpi_definitions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_upload_batches"
    ADD CONSTRAINT "kpi_upload_batches_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_upload_batches"
    ADD CONSTRAINT "kpi_upload_batches_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."kpi_upload_rows"
    ADD CONSTRAINT "kpi_upload_rows_kpi_definition_id_fkey" FOREIGN KEY ("kpi_definition_id") REFERENCES "public"."kpi_definitions"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_upload_rows"
    ADD CONSTRAINT "kpi_upload_rows_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "public"."staff_members"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."kpi_upload_rows"
    ADD CONSTRAINT "kpi_upload_rows_upload_batch_id_fkey" FOREIGN KEY ("upload_batch_id") REFERENCES "public"."kpi_upload_batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."quote_service_options"
    ADD CONSTRAINT "quote_service_options_service_fk" FOREIGN KEY ("service_id") REFERENCES "public"."quote_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."quote_service_role_prices"
    ADD CONSTRAINT "quote_service_role_prices_service_fk" FOREIGN KEY ("service_id") REFERENCES "public"."quote_services"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."quote_services"
    ADD CONSTRAINT "quote_services_link_to_base_fk" FOREIGN KEY ("link_to_base_service_id") REFERENCES "public"."quote_services"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."quote_services"
    ADD CONSTRAINT "quote_services_section_fk" FOREIGN KEY ("section_id") REFERENCES "public"."quote_sections"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."raw_sales_import_rows"
    ADD CONSTRAINT "raw_sales_import_rows_import_batch_id_fkey" FOREIGN KEY ("import_batch_id") REFERENCES "public"."sales_import_batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."remuneration_plan_rates"
    ADD CONSTRAINT "remuneration_plan_rates_remuneration_plan_id_fkey" FOREIGN KEY ("remuneration_plan_id") REFERENCES "public"."remuneration_plans"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sales_daily_sheets_import_batches"
    ADD CONSTRAINT "sales_daily_sheets_import_batches_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sales_daily_sheets_import_batches"
    ADD CONSTRAINT "sales_daily_sheets_import_batches_payroll_import_batch_id_fkey" FOREIGN KEY ("payroll_import_batch_id") REFERENCES "public"."sales_import_batches"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sales_daily_sheets_import_batches"
    ADD CONSTRAINT "sales_daily_sheets_import_batches_selected_location_id_fkey" FOREIGN KEY ("selected_location_id") REFERENCES "public"."locations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sales_import_batches"
    ADD CONSTRAINT "sales_import_batches_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."sales_transactions"
    ADD CONSTRAINT "sales_transactions_import_batch_id_fkey" FOREIGN KEY ("import_batch_id") REFERENCES "public"."sales_import_batches"("id");



ALTER TABLE ONLY "public"."sales_transactions"
    ADD CONSTRAINT "sales_transactions_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."sales_transactions"
    ADD CONSTRAINT "sales_transactions_raw_row_id_fkey" FOREIGN KEY ("raw_row_id") REFERENCES "public"."raw_sales_import_rows"("id");



ALTER TABLE ONLY "public"."saved_quote_line_options"
    ADD CONSTRAINT "saved_quote_line_options_line_fk" FOREIGN KEY ("saved_quote_line_id") REFERENCES "public"."saved_quote_lines"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."saved_quote_line_options"
    ADD CONSTRAINT "saved_quote_line_options_option_fk" FOREIGN KEY ("service_option_id") REFERENCES "public"."quote_service_options"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."saved_quote_lines"
    ADD CONSTRAINT "saved_quote_lines_saved_quote_fk" FOREIGN KEY ("saved_quote_id") REFERENCES "public"."saved_quotes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."saved_quote_lines"
    ADD CONSTRAINT "saved_quote_lines_section_fk" FOREIGN KEY ("section_id") REFERENCES "public"."quote_sections"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."saved_quote_lines"
    ADD CONSTRAINT "saved_quote_lines_service_fk" FOREIGN KEY ("service_id") REFERENCES "public"."quote_services"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."saved_quote_section_totals"
    ADD CONSTRAINT "saved_quote_section_totals_saved_quote_fk" FOREIGN KEY ("saved_quote_id") REFERENCES "public"."saved_quotes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."saved_quotes"
    ADD CONSTRAINT "saved_quotes_stylist_staff_member_fk" FOREIGN KEY ("stylist_staff_member_id") REFERENCES "public"."staff_members"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."saved_quotes"
    ADD CONSTRAINT "saved_quotes_stylist_user_fk" FOREIGN KEY ("stylist_user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."staff_capacity_monthly"
    ADD CONSTRAINT "staff_capacity_monthly_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "public"."staff_members"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."staff_member_user_access"
    ADD CONSTRAINT "staff_member_user_access_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "public"."staff_members"("id");



ALTER TABLE "public"."kpi_definitions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kpi_definitions_elevated_select" ON "public"."kpi_definitions" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."kpi_manual_inputs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kpi_manual_inputs_elevated_select" ON "public"."kpi_manual_inputs" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."kpi_monthly_values" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kpi_monthly_values_elevated_select" ON "public"."kpi_monthly_values" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."kpi_targets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kpi_targets_elevated_select" ON "public"."kpi_targets" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."kpi_upload_batches" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kpi_upload_batches_elevated_select" ON "public"."kpi_upload_batches" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."kpi_upload_rows" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "kpi_upload_rows_elevated_select" ON "public"."kpi_upload_rows" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."locations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_master" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "product_master_elevated_insert" ON "public"."product_master" FOR INSERT TO "authenticated" WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



CREATE POLICY "product_master_elevated_select" ON "public"."product_master" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



CREATE POLICY "product_master_elevated_update" ON "public"."product_master" FOR UPDATE TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access")) WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."quote_sections" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quote_sections_elevated_all" ON "public"."quote_sections" TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access")) WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."quote_service_options" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quote_service_options_elevated_all" ON "public"."quote_service_options" TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access")) WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."quote_service_role_prices" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quote_service_role_prices_elevated_all" ON "public"."quote_service_role_prices" TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access")) WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."quote_services" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quote_services_elevated_all" ON "public"."quote_services" TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access")) WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."quote_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "quote_settings_elevated_all" ON "public"."quote_settings" TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access")) WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."raw_sales_import_rows" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."remuneration_plan_rates" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "remuneration_plan_rates_elevated_all" ON "public"."remuneration_plan_rates" TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access")) WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."remuneration_plans" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "remuneration_plans_elevated_all" ON "public"."remuneration_plans" TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access")) WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



CREATE POLICY "sales_daily_sheets_batches_select_own" ON "public"."sales_daily_sheets_import_batches" FOR SELECT TO "authenticated" USING (("created_by" = "auth"."uid"()));



ALTER TABLE "public"."sales_daily_sheets_import_batches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sales_daily_sheets_staged_rows" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sales_import_batches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sales_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."saved_quote_line_options" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "saved_quote_line_options_authenticated_select" ON "public"."saved_quote_line_options" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "saved_quote_line_options_author_insert" ON "public"."saved_quote_line_options" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM ("public"."saved_quote_lines" "sql_"
     JOIN "public"."saved_quotes" "sq" ON (("sq"."id" = "sql_"."saved_quote_id")))
  WHERE (("sql_"."id" = "saved_quote_line_options"."saved_quote_line_id") AND ("sq"."stylist_user_id" = "auth"."uid"())))));



CREATE POLICY "saved_quote_line_options_author_select" ON "public"."saved_quote_line_options" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."saved_quote_lines" "sql_"
     JOIN "public"."saved_quotes" "sq" ON (("sq"."id" = "sql_"."saved_quote_id")))
  WHERE (("sql_"."id" = "saved_quote_line_options"."saved_quote_line_id") AND ("sq"."stylist_user_id" = "auth"."uid"())))));



CREATE POLICY "saved_quote_line_options_elevated_select" ON "public"."saved_quote_line_options" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."saved_quote_lines" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "saved_quote_lines_authenticated_select" ON "public"."saved_quote_lines" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "saved_quote_lines_author_insert" ON "public"."saved_quote_lines" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."saved_quotes" "sq"
  WHERE (("sq"."id" = "saved_quote_lines"."saved_quote_id") AND ("sq"."stylist_user_id" = "auth"."uid"())))));



CREATE POLICY "saved_quote_lines_author_select" ON "public"."saved_quote_lines" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."saved_quotes" "sq"
  WHERE (("sq"."id" = "saved_quote_lines"."saved_quote_id") AND ("sq"."stylist_user_id" = "auth"."uid"())))));



CREATE POLICY "saved_quote_lines_elevated_select" ON "public"."saved_quote_lines" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."saved_quote_section_totals" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "saved_quote_section_totals_authenticated_select" ON "public"."saved_quote_section_totals" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "saved_quote_section_totals_author_insert" ON "public"."saved_quote_section_totals" FOR INSERT TO "authenticated" WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."saved_quotes" "sq"
  WHERE (("sq"."id" = "saved_quote_section_totals"."saved_quote_id") AND ("sq"."stylist_user_id" = "auth"."uid"())))));



CREATE POLICY "saved_quote_section_totals_author_select" ON "public"."saved_quote_section_totals" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."saved_quotes" "sq"
  WHERE (("sq"."id" = "saved_quote_section_totals"."saved_quote_id") AND ("sq"."stylist_user_id" = "auth"."uid"())))));



CREATE POLICY "saved_quote_section_totals_elevated_select" ON "public"."saved_quote_section_totals" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."saved_quotes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "saved_quotes_authenticated_select" ON "public"."saved_quotes" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "saved_quotes_author_insert" ON "public"."saved_quotes" FOR INSERT TO "authenticated" WITH CHECK (("stylist_user_id" = "auth"."uid"()));



CREATE POLICY "saved_quotes_author_select" ON "public"."saved_quotes" FOR SELECT TO "authenticated" USING (("stylist_user_id" = "auth"."uid"()));



CREATE POLICY "saved_quotes_elevated_select" ON "public"."saved_quotes" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."staff_capacity_monthly" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "staff_capacity_monthly_elevated_select" ON "public"."staff_capacity_monthly" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."staff_member_user_access" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."staff_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "staff_members_elevated_insert" ON "public"."staff_members" FOR INSERT TO "authenticated" WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



CREATE POLICY "staff_members_elevated_select" ON "public"."staff_members" FOR SELECT TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



CREATE POLICY "staff_members_elevated_update" ON "public"."staff_members" FOR UPDATE TO "authenticated" USING (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access")) WITH CHECK (( SELECT "private"."user_has_elevated_access"() AS "user_has_elevated_access"));



ALTER TABLE "public"."stg_dimproducts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stg_dimremunerationplans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stg_dimstaff" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stg_salesdailysheets" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_can_read_own_access" ON "public"."staff_member_user_access" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



GRANT USAGE ON SCHEMA "private" TO "authenticated";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



REVOKE ALL ON FUNCTION "private"."kpi_caller_access_role"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."kpi_caller_access_role"() TO "authenticated";
GRANT ALL ON FUNCTION "private"."kpi_caller_access_role"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."kpi_caller_staff_member_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."kpi_caller_staff_member_id"() TO "authenticated";
GRANT ALL ON FUNCTION "private"."kpi_caller_staff_member_id"() TO "service_role";



REVOKE ALL ON FUNCTION "private"."kpi_resolve_scope"("p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."kpi_resolve_scope"("p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "private"."kpi_resolve_scope"("p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "private"."run_sales_daily_sheets_merge_if_installed"("p_batch_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."run_sales_daily_sheets_merge_if_installed"("p_batch_id" "uuid") TO "authenticated";



REVOKE ALL ON FUNCTION "private"."user_can_manage_access_mappings"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."user_has_elevated_access"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."user_has_elevated_access"() TO "authenticated";



REVOKE ALL ON FUNCTION "public"."admin_delete_remuneration_plan_if_unused"("p_plan_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_delete_remuneration_plan_if_unused"("p_plan_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_delete_remuneration_plan_if_unused"("p_plan_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_delete_remuneration_plan_if_unused"("p_plan_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_remuneration_staff_counts"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_remuneration_staff_counts"() TO "anon";
GRANT ALL ON FUNCTION "public"."admin_remuneration_staff_counts"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_remuneration_staff_counts"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."admin_staff_for_remuneration_plan"("p_plan_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."admin_staff_for_remuneration_plan"("p_plan_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_staff_for_remuneration_plan"("p_plan_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_staff_for_remuneration_plan"("p_plan_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."apply_sales_daily_sheets_to_payroll"("p_batch_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."apply_sales_daily_sheets_to_payroll"("p_batch_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_sales_daily_sheets_to_payroll"("p_batch_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."bulk_stage_sales_rows"("p_rows" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."bulk_stage_sales_rows"("p_rows" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulk_stage_sales_rows"("p_rows" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."caller_can_manage_access_mappings"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."caller_can_manage_access_mappings"() TO "anon";
GRANT ALL ON FUNCTION "public"."caller_can_manage_access_mappings"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."caller_can_manage_access_mappings"() TO "service_role";



GRANT ALL ON FUNCTION "public"."clear_stg_salesdailysheets"() TO "anon";
GRANT ALL ON FUNCTION "public"."clear_stg_salesdailysheets"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_stg_salesdailysheets"() TO "service_role";



GRANT ALL ON TABLE "public"."staff_member_user_access" TO "service_role";



GRANT ALL ON FUNCTION "public"."create_access_mapping"("p_user_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_access_mapping"("p_user_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_sales_import_batch"("p_source_file_name" "text", "p_source_name" "text", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_sales_import_batch"("p_source_file_name" "text", "p_source_name" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_sales_import_batch"("p_source_file_name" "text", "p_source_name" "text", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_all_sales_daily_sheets_import_data"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_all_sales_daily_sheets_import_data"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_all_sales_daily_sheets_import_data"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_quote_section"("p_section_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_quote_section"("p_section_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_quote_section"("p_section_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_quote_section"("p_section_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_sales_daily_sheets_staged_rows_for_batch"("p_batch_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_sales_daily_sheets_staged_rows_for_batch"("p_batch_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_sales_daily_sheets_staged_rows_for_batch"("p_batch_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_sales_daily_sheets_staged_rows_for_batch"("p_batch_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."delete_saved_quote"("p_saved_quote_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."delete_saved_quote"("p_saved_quote_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_saved_quote"("p_saved_quote_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_saved_quote"("p_saved_quote_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_is_admin_or_manager"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_is_admin_or_manager"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_my_access_role"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_my_access_role"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_my_staff_member_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_my_staff_member_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_active_quote_config"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_active_quote_config"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_active_quote_config"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_active_quote_config"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_admin_access_mappings"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_admin_access_mappings"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_access_mappings"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_access_mappings"() TO "service_role";



GRANT ALL ON TABLE "public"."locations" TO "service_role";



GRANT ALL ON TABLE "public"."product_master" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."product_master" TO "authenticated";



GRANT ALL ON TABLE "public"."remuneration_plan_rates" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."remuneration_plan_rates" TO "authenticated";



GRANT ALL ON TABLE "public"."remuneration_plans" TO "service_role";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE "public"."remuneration_plans" TO "authenticated";



GRANT ALL ON TABLE "public"."sales_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."staff_members" TO "service_role";
GRANT SELECT,INSERT,UPDATE ON TABLE "public"."staff_members" TO "authenticated";



GRANT ALL ON TABLE "public"."v_sales_transactions_powerbi_parity" TO "service_role";



GRANT ALL ON TABLE "public"."v_commission_calculations_core" TO "service_role";



GRANT ALL ON TABLE "public"."v_commission_calculations_qa" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_lines" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_lines_weekly" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_payroll_lines_weekly"("p_pay_week_start" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_payroll_lines_weekly"("p_pay_week_start" "date") TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_summary_weekly" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_payroll_summary_weekly"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_payroll_summary_weekly"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_kpi_guests_per_month_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_kpi_guests_per_month_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_kpi_guests_per_month_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_kpi_guests_per_month_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_kpi_revenue_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_kpi_revenue_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_kpi_revenue_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_kpi_revenue_live"("p_period_start" "date", "p_scope" "text", "p_location_id" "uuid", "p_staff_member_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_location_id_from_filename"("p_file_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_location_id_from_filename"("p_file_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_location_id_from_filename"("p_file_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_access_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_access_profile"() TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_lines_weekly_final" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_commission_lines_weekly"("p_pay_week_start" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_commission_lines_weekly"("p_pay_week_start" "date") TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_summary_weekly_final" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_commission_summary_weekly"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_commission_summary_weekly"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_saved_quote_detail"("p_saved_quote_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_saved_quote_detail"("p_saved_quote_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_saved_quote_detail"("p_saved_quote_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_saved_quote_detail"("p_saved_quote_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_saved_quotes_search"("p_search" "text", "p_stylist" "text", "p_guest_name" "text", "p_date_from" "date", "p_date_to" "date", "p_limit" integer, "p_offset" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_saved_quotes_search"("p_search" "text", "p_stylist" "text", "p_guest_name" "text", "p_date_from" "date", "p_date_to" "date", "p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_saved_quotes_search"("p_search" "text", "p_stylist" "text", "p_guest_name" "text", "p_date_from" "date", "p_date_to" "date", "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_saved_quotes_search"("p_search" "text", "p_stylist" "text", "p_guest_name" "text", "p_date_from" "date", "p_date_to" "date", "p_limit" integer, "p_offset" integer) TO "service_role";



REVOKE ALL ON FUNCTION "public"."insert_sales_daily_sheets_staged_rows_chunk"("p_rows" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."insert_sales_daily_sheets_staged_rows_chunk"("p_rows" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."insert_sales_daily_sheets_staged_rows_chunk"("p_rows" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_sales_daily_sheets_staged_rows_chunk"("p_rows" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_staged_sales_row"("p_category" "text", "p_first_name" "text", "p_qty" "text", "p_prod_total" "text", "p_prod_id" "text", "p_date" "text", "p_source_document_number" "text", "p_description" "text", "p_whole_name" "text", "p_product_type" "text", "p_parent_prod_type" "text", "p_prod_cat" "text", "p_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."insert_staged_sales_row"("p_category" "text", "p_first_name" "text", "p_qty" "text", "p_prod_total" "text", "p_prod_id" "text", "p_date" "text", "p_source_document_number" "text", "p_description" "text", "p_whole_name" "text", "p_product_type" "text", "p_parent_prod_type" "text", "p_prod_cat" "text", "p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_staged_sales_row"("p_category" "text", "p_first_name" "text", "p_qty" "text", "p_prod_total" "text", "p_prod_id" "text", "p_date" "text", "p_source_document_number" "text", "p_description" "text", "p_whole_name" "text", "p_product_type" "text", "p_parent_prod_type" "text", "p_prod_cat" "text", "p_name" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."list_active_locations_for_import"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."list_active_locations_for_import"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_active_locations_for_import"() TO "service_role";



GRANT ALL ON FUNCTION "public"."load_raw_sales_rows_to_transactions"("p_import_batch_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."load_raw_sales_rows_to_transactions"("p_import_batch_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."load_raw_sales_rows_to_transactions"("p_import_batch_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."load_staged_sales_rows_to_raw"("p_import_batch_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."load_staged_sales_rows_to_raw"("p_import_batch_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."load_staged_sales_rows_to_raw"("p_import_batch_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."normalise_customer_name"("p_raw" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."normalise_customer_name"("p_raw" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."normalise_customer_name"("p_raw" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalise_customer_name"("p_raw" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."save_guest_quote"("payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_guest_quote"("payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."save_guest_quote"("payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_guest_quote"("payload" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."save_quote_service"("payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."save_quote_service"("payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."save_quote_service"("payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_quote_service"("payload" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."search_auth_users"("p_search" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."search_auth_users"("p_search" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."search_auth_users"("p_search" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_auth_users"("p_search" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."search_staff_members"("p_search" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_staff_members"("p_search" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text", "p_location_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text", "p_location_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text", "p_location_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_access_mapping"("p_mapping_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_access_mapping"("p_mapping_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) TO "service_role";



GRANT ALL ON TABLE "public"."kpi_definitions" TO "anon";
GRANT ALL ON TABLE "public"."kpi_definitions" TO "authenticated";
GRANT ALL ON TABLE "public"."kpi_definitions" TO "service_role";



GRANT ALL ON TABLE "public"."kpi_manual_inputs" TO "anon";
GRANT ALL ON TABLE "public"."kpi_manual_inputs" TO "authenticated";
GRANT ALL ON TABLE "public"."kpi_manual_inputs" TO "service_role";



GRANT ALL ON TABLE "public"."kpi_monthly_values" TO "anon";
GRANT ALL ON TABLE "public"."kpi_monthly_values" TO "authenticated";
GRANT ALL ON TABLE "public"."kpi_monthly_values" TO "service_role";



GRANT ALL ON TABLE "public"."kpi_targets" TO "anon";
GRANT ALL ON TABLE "public"."kpi_targets" TO "authenticated";
GRANT ALL ON TABLE "public"."kpi_targets" TO "service_role";



GRANT ALL ON TABLE "public"."kpi_upload_batches" TO "anon";
GRANT ALL ON TABLE "public"."kpi_upload_batches" TO "authenticated";
GRANT ALL ON TABLE "public"."kpi_upload_batches" TO "service_role";



GRANT ALL ON TABLE "public"."kpi_upload_rows" TO "anon";
GRANT ALL ON TABLE "public"."kpi_upload_rows" TO "authenticated";
GRANT ALL ON TABLE "public"."kpi_upload_rows" TO "service_role";



GRANT ALL ON TABLE "public"."quote_sections" TO "anon";
GRANT ALL ON TABLE "public"."quote_sections" TO "authenticated";
GRANT ALL ON TABLE "public"."quote_sections" TO "service_role";



GRANT ALL ON TABLE "public"."quote_service_options" TO "anon";
GRANT ALL ON TABLE "public"."quote_service_options" TO "authenticated";
GRANT ALL ON TABLE "public"."quote_service_options" TO "service_role";



GRANT ALL ON TABLE "public"."quote_service_role_prices" TO "anon";
GRANT ALL ON TABLE "public"."quote_service_role_prices" TO "authenticated";
GRANT ALL ON TABLE "public"."quote_service_role_prices" TO "service_role";



GRANT ALL ON TABLE "public"."quote_services" TO "anon";
GRANT ALL ON TABLE "public"."quote_services" TO "authenticated";
GRANT ALL ON TABLE "public"."quote_services" TO "service_role";



GRANT ALL ON TABLE "public"."quote_settings" TO "anon";
GRANT ALL ON TABLE "public"."quote_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."quote_settings" TO "service_role";



GRANT ALL ON TABLE "public"."raw_sales_import_rows" TO "service_role";



GRANT ALL ON TABLE "public"."sales_daily_sheets_import_batches" TO "anon";
GRANT ALL ON TABLE "public"."sales_daily_sheets_import_batches" TO "authenticated";
GRANT ALL ON TABLE "public"."sales_daily_sheets_import_batches" TO "service_role";



GRANT ALL ON TABLE "public"."sales_daily_sheets_staged_rows" TO "anon";
GRANT ALL ON TABLE "public"."sales_daily_sheets_staged_rows" TO "authenticated";
GRANT ALL ON TABLE "public"."sales_daily_sheets_staged_rows" TO "service_role";



GRANT ALL ON TABLE "public"."sales_import_batches" TO "service_role";



GRANT ALL ON TABLE "public"."saved_quote_line_options" TO "anon";
GRANT ALL ON TABLE "public"."saved_quote_line_options" TO "authenticated";
GRANT ALL ON TABLE "public"."saved_quote_line_options" TO "service_role";



GRANT ALL ON TABLE "public"."saved_quote_lines" TO "anon";
GRANT ALL ON TABLE "public"."saved_quote_lines" TO "authenticated";
GRANT ALL ON TABLE "public"."saved_quote_lines" TO "service_role";



GRANT ALL ON TABLE "public"."saved_quote_section_totals" TO "anon";
GRANT ALL ON TABLE "public"."saved_quote_section_totals" TO "authenticated";
GRANT ALL ON TABLE "public"."saved_quote_section_totals" TO "service_role";



GRANT ALL ON TABLE "public"."saved_quotes" TO "anon";
GRANT ALL ON TABLE "public"."saved_quotes" TO "authenticated";
GRANT ALL ON TABLE "public"."saved_quotes" TO "service_role";



GRANT ALL ON TABLE "public"."staff_capacity_monthly" TO "anon";
GRANT ALL ON TABLE "public"."staff_capacity_monthly" TO "authenticated";
GRANT ALL ON TABLE "public"."staff_capacity_monthly" TO "service_role";



GRANT ALL ON TABLE "public"."stg_dimproducts" TO "service_role";



GRANT ALL ON TABLE "public"."stg_dimremunerationplans" TO "service_role";



GRANT ALL ON TABLE "public"."stg_dimstaff" TO "service_role";



GRANT ALL ON TABLE "public"."stg_salesdailysheets" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_summary_by_location" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_summary_by_stylist" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_user_access_overview" TO "service_role";



GRANT ALL ON TABLE "public"."v_sales_transactions_enriched" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_lines_secure" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_lines_access_scoped" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_lines_final" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_summary_secure" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_summary_self_service" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_summary_access_scoped" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_summary_final" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







