


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


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






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


CREATE OR REPLACE FUNCTION "public"."caller_can_manage_access_mappings"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
    AS $$
  SELECT private.user_can_manage_access_mappings();
$$;


ALTER FUNCTION "public"."caller_can_manage_access_mappings"() OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."get_admin_access_mappings"() RETURNS TABLE("user_id" "uuid", "email" "text", "access_role" "text", "is_active" boolean, "created_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
    AS $$
    SELECT 
        sma.user_id,
        COALESCE(au.email::text, '') AS email,
        sma.access_role,
        sma.is_active,
        sma.created_at
    FROM public.staff_member_user_access sma
    LEFT JOIN auth.users au ON au.id = sma.user_id
    WHERE private.user_has_elevated_access()     -- ← This is the important security check
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
    CONSTRAINT "remuneration_plan_rates_category_valid" CHECK (("commission_category" = ANY (ARRAY['retail_product'::"text", 'professional_product'::"text", 'service'::"text", 'voucher'::"text", 'toner_with_other_service'::"text", 'extensions_product'::"text", 'extensions_service'::"text", 'creative_director'::"text"]))),
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
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."staff_members" OWNER TO "postgres";


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
             LEFT JOIN "public"."staff_members" "sc" ON (("st"."staff_commission_id" = "sc"."id")))
             LEFT JOIN "public"."staff_members" "sw" ON (("st"."staff_work_id" = "sw"."id")))
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
                    WHEN (("upper"(TRIM(BOTH FROM COALESCE("b"."work_primary_role", ''::"text"))) = 'ASSISTANT'::"text") AND ("b"."commission_can_use_assistants" = false)) THEN NULL::"text"
                    WHEN (("upper"(TRIM(BOTH FROM COALESCE("b"."work_primary_role", ''::"text"))) = 'ASSISTANT'::"text") AND ("b"."commission_can_use_assistants" = true)) THEN "b"."staff_commission_name"
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
                    WHEN ("upper"(COALESCE("b"."product_header", ''::"text")) ~~ '%CREATIVE DIRECTOR%'::"text") THEN 'creative_director'::"text"
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
    r.staff_work_name as staff_commission_name,
    r.staff_work_name,
    r.first_name as staff_paid_name,
    case
      when coalesce(r.staff_work_name, '') = coalesce(r.first_name, '') then 'Yes'
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


CREATE OR REPLACE FUNCTION "public"."search_auth_users"("p_search" "text" DEFAULT NULL::"text") RETURNS TABLE("user_id" "uuid", "email" "text")
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public', 'auth', 'pg_temp'
    AS $$
  select
    u.id,
    coalesce(u.email::text, '') as email
  from auth.users u
  where (select private.user_has_elevated_access())
    and coalesce(u.email, '') <> ''
    and not exists (
      select 1
      from public.staff_member_user_access m
      where m.user_id = u.id
    )
    and (
      p_search is null
      or length(trim(p_search)) = 0
      or u.email::text ilike '%' || trim(p_search) || '%'
    )
  order by u.email
  limit 100
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


CREATE OR REPLACE FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'storage', 'auth', 'pg_temp'
    AS $$
DECLARE
  v_path text := trim(p_storage_path);
  v_uid uuid := auth.uid();
  v_batch_id uuid := gen_random_uuid();
  v_bucket_id text;
  v_found boolean;
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

  INSERT INTO public.sales_daily_sheets_import_batches (
    id,
    storage_path,
    status,
    message,
    rows_staged,
    rows_loaded,
    created_by
  )
  VALUES (
    v_batch_id,
    v_path,
    'registered',
    'Object verified in Storage. Hook your existing import job here to populate rows_staged / rows_loaded.',
    NULL,
    NULL,
    v_uid
  );

  -- Optional: call your existing import routine, e.g.:
  -- PERFORM private.your_sales_daily_import_worker(v_batch_id, v_path);

  RETURN jsonb_build_object(
    'success', true,
    'message', 'Import batch registered. Connect your ETL or Edge Function to process the CSV.',
    'storage_path', v_path,
    'batch_id', v_batch_id,
    'rows_staged', NULL,
    'rows_loaded', NULL
  );
END;
$$;


ALTER FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text") OWNER TO "postgres";


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
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."sales_daily_sheets_import_batches" OWNER TO "postgres";


COMMENT ON TABLE "public"."sales_daily_sheets_import_batches" IS 'Audit log for Sales Daily Sheets uploads; RPC trigger_sales_daily_sheets_import inserts rows.';



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
    "voucher" "text",
    "can_use_assistants" "text",
    "toner_with_other_service" "text",
    "extensions_product" "text",
    "extensions_service" "text",
    "creative_director" "text",
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
             LEFT JOIN "public"."staff_members" "sw" ON (("st"."staff_work_id" = "sw"."id")))
             LEFT JOIN "public"."staff_members" "sp" ON (("st"."staff_paid_id" = "sp"."id")))
             LEFT JOIN "public"."staff_members" "sc" ON (("st"."staff_commission_id" = "sc"."id")))
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



ALTER TABLE ONLY "public"."sales_import_batches"
    ADD CONSTRAINT "sales_import_batches_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_transactions"
    ADD CONSTRAINT "sales_transactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sales_transactions"
    ADD CONSTRAINT "sales_transactions_raw_row_id_key" UNIQUE ("raw_row_id");



ALTER TABLE ONLY "public"."staff_member_user_access"
    ADD CONSTRAINT "staff_member_user_access_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."staff_members"
    ADD CONSTRAINT "staff_members_full_name_key" UNIQUE ("full_name");



ALTER TABLE ONLY "public"."staff_members"
    ADD CONSTRAINT "staff_members_pkey" PRIMARY KEY ("id");



CREATE INDEX "idx_raw_sales_import_rows_batch_id" ON "public"."raw_sales_import_rows" USING "btree" ("import_batch_id");



CREATE INDEX "sales_daily_sheets_import_batches_created_at_idx" ON "public"."sales_daily_sheets_import_batches" USING "btree" ("created_at" DESC);



CREATE UNIQUE INDEX "ux_staff_member_user_access_user_staff_role" ON "public"."staff_member_user_access" USING "btree" ("user_id", COALESCE("staff_member_id", '00000000-0000-0000-0000-000000000000'::"uuid"), "access_role");



CREATE OR REPLACE TRIGGER "trg_locations_updated_at" BEFORE UPDATE ON "public"."locations" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_product_master_updated_at" BEFORE UPDATE ON "public"."product_master" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_raw_sales_import_rows_updated_at" BEFORE UPDATE ON "public"."raw_sales_import_rows" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_remuneration_plan_rates_updated_at" BEFORE UPDATE ON "public"."remuneration_plan_rates" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_remuneration_plans_updated_at" BEFORE UPDATE ON "public"."remuneration_plans" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_sales_import_batches_updated_at" BEFORE UPDATE ON "public"."sales_import_batches" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_staff_member_user_access_updated_at" BEFORE UPDATE ON "public"."staff_member_user_access" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



ALTER TABLE ONLY "public"."raw_sales_import_rows"
    ADD CONSTRAINT "raw_sales_import_rows_import_batch_id_fkey" FOREIGN KEY ("import_batch_id") REFERENCES "public"."sales_import_batches"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."remuneration_plan_rates"
    ADD CONSTRAINT "remuneration_plan_rates_remuneration_plan_id_fkey" FOREIGN KEY ("remuneration_plan_id") REFERENCES "public"."remuneration_plans"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."sales_daily_sheets_import_batches"
    ADD CONSTRAINT "sales_daily_sheets_import_batches_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."sales_import_batches"
    ADD CONSTRAINT "sales_import_batches_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."sales_transactions"
    ADD CONSTRAINT "sales_transactions_import_batch_id_fkey" FOREIGN KEY ("import_batch_id") REFERENCES "public"."sales_import_batches"("id");



ALTER TABLE ONLY "public"."sales_transactions"
    ADD CONSTRAINT "sales_transactions_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");



ALTER TABLE ONLY "public"."sales_transactions"
    ADD CONSTRAINT "sales_transactions_raw_row_id_fkey" FOREIGN KEY ("raw_row_id") REFERENCES "public"."raw_sales_import_rows"("id");



ALTER TABLE ONLY "public"."staff_member_user_access"
    ADD CONSTRAINT "staff_member_user_access_staff_member_id_fkey" FOREIGN KEY ("staff_member_id") REFERENCES "public"."staff_members"("id");



ALTER TABLE "public"."locations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_master" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."raw_sales_import_rows" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."remuneration_plan_rates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."remuneration_plans" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "sales_daily_sheets_batches_select_own" ON "public"."sales_daily_sheets_import_batches" FOR SELECT TO "authenticated" USING (("created_by" = "auth"."uid"()));



ALTER TABLE "public"."sales_daily_sheets_import_batches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sales_import_batches" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sales_transactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."staff_member_user_access" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."staff_members" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_can_read_own_access" ON "public"."staff_member_user_access" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "private" TO "authenticated";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

























































































































































REVOKE ALL ON FUNCTION "private"."user_can_manage_access_mappings"() FROM PUBLIC;



REVOKE ALL ON FUNCTION "private"."user_has_elevated_access"() FROM PUBLIC;
GRANT ALL ON FUNCTION "private"."user_has_elevated_access"() TO "authenticated";



GRANT ALL ON FUNCTION "public"."bulk_stage_sales_rows"("p_rows" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."bulk_stage_sales_rows"("p_rows" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulk_stage_sales_rows"("p_rows" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."clear_stg_salesdailysheets"() TO "anon";
GRANT ALL ON FUNCTION "public"."clear_stg_salesdailysheets"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_stg_salesdailysheets"() TO "service_role";



GRANT ALL ON TABLE "public"."staff_member_user_access" TO "service_role";



GRANT ALL ON FUNCTION "public"."create_access_mapping"("p_user_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_access_mapping"("p_user_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_sales_import_batch"("p_source_file_name" "text", "p_source_name" "text", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_sales_import_batch"("p_source_file_name" "text", "p_source_name" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_sales_import_batch"("p_source_file_name" "text", "p_source_name" "text", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_is_admin_or_manager"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_is_admin_or_manager"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_my_access_role"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_my_access_role"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."fn_my_staff_member_id"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."fn_my_staff_member_id"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."get_admin_access_mappings"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."get_admin_access_mappings"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_access_mappings"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_access_mappings"() TO "service_role";



GRANT ALL ON TABLE "public"."locations" TO "service_role";



GRANT ALL ON TABLE "public"."product_master" TO "service_role";



GRANT ALL ON TABLE "public"."remuneration_plan_rates" TO "service_role";



GRANT ALL ON TABLE "public"."remuneration_plans" TO "service_role";



GRANT ALL ON TABLE "public"."sales_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."staff_members" TO "service_role";



GRANT ALL ON TABLE "public"."v_sales_transactions_powerbi_parity" TO "anon";
GRANT ALL ON TABLE "public"."v_sales_transactions_powerbi_parity" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sales_transactions_powerbi_parity" TO "service_role";



GRANT ALL ON TABLE "public"."v_commission_calculations_core" TO "anon";
GRANT ALL ON TABLE "public"."v_commission_calculations_core" TO "authenticated";
GRANT ALL ON TABLE "public"."v_commission_calculations_core" TO "service_role";



GRANT ALL ON TABLE "public"."v_commission_calculations_qa" TO "anon";
GRANT ALL ON TABLE "public"."v_commission_calculations_qa" TO "authenticated";
GRANT ALL ON TABLE "public"."v_commission_calculations_qa" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_lines" TO "anon";
GRANT ALL ON TABLE "public"."v_admin_payroll_lines" TO "authenticated";
GRANT ALL ON TABLE "public"."v_admin_payroll_lines" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_lines_weekly" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_payroll_lines_weekly"("p_pay_week_start" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_payroll_lines_weekly"("p_pay_week_start" "date") TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_summary_weekly" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_payroll_summary_weekly"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_payroll_summary_weekly"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_location_id_from_filename"("p_file_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_location_id_from_filename"("p_file_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_location_id_from_filename"("p_file_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_access_profile"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_access_profile"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."caller_can_manage_access_mappings"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."caller_can_manage_access_mappings"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."caller_can_manage_access_mappings"() TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_lines_weekly_final" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_commission_lines_weekly"("p_pay_week_start" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_commission_lines_weekly"("p_pay_week_start" "date") TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_summary_weekly_final" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_commission_summary_weekly"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_commission_summary_weekly"() TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_staged_sales_row"("p_category" "text", "p_first_name" "text", "p_qty" "text", "p_prod_total" "text", "p_prod_id" "text", "p_date" "text", "p_source_document_number" "text", "p_description" "text", "p_whole_name" "text", "p_product_type" "text", "p_parent_prod_type" "text", "p_prod_cat" "text", "p_name" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."insert_staged_sales_row"("p_category" "text", "p_first_name" "text", "p_qty" "text", "p_prod_total" "text", "p_prod_id" "text", "p_date" "text", "p_source_document_number" "text", "p_description" "text", "p_whole_name" "text", "p_product_type" "text", "p_parent_prod_type" "text", "p_prod_cat" "text", "p_name" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_staged_sales_row"("p_category" "text", "p_first_name" "text", "p_qty" "text", "p_prod_total" "text", "p_prod_id" "text", "p_date" "text", "p_source_document_number" "text", "p_description" "text", "p_whole_name" "text", "p_product_type" "text", "p_parent_prod_type" "text", "p_prod_cat" "text", "p_name" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."load_raw_sales_rows_to_transactions"("p_import_batch_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."load_raw_sales_rows_to_transactions"("p_import_batch_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."load_raw_sales_rows_to_transactions"("p_import_batch_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."load_staged_sales_rows_to_raw"("p_import_batch_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."load_staged_sales_rows_to_raw"("p_import_batch_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."load_staged_sales_rows_to_raw"("p_import_batch_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."search_auth_users"("p_search" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_auth_users"("p_search" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."search_staff_members"("p_search" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_staff_members"("p_search" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."trigger_sales_daily_sheets_import"("p_storage_path" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_access_mapping"("p_mapping_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_access_mapping"("p_mapping_id" "uuid", "p_staff_member_id" "uuid", "p_access_role" "text", "p_is_active" boolean) TO "service_role";


















GRANT ALL ON TABLE "public"."raw_sales_import_rows" TO "service_role";



GRANT ALL ON TABLE "public"."sales_daily_sheets_import_batches" TO "anon";
GRANT ALL ON TABLE "public"."sales_daily_sheets_import_batches" TO "authenticated";
GRANT ALL ON TABLE "public"."sales_daily_sheets_import_batches" TO "service_role";



GRANT ALL ON TABLE "public"."sales_import_batches" TO "service_role";



GRANT ALL ON TABLE "public"."stg_dimproducts" TO "anon";
GRANT ALL ON TABLE "public"."stg_dimproducts" TO "authenticated";
GRANT ALL ON TABLE "public"."stg_dimproducts" TO "service_role";



GRANT ALL ON TABLE "public"."stg_dimremunerationplans" TO "anon";
GRANT ALL ON TABLE "public"."stg_dimremunerationplans" TO "authenticated";
GRANT ALL ON TABLE "public"."stg_dimremunerationplans" TO "service_role";



GRANT ALL ON TABLE "public"."stg_dimstaff" TO "anon";
GRANT ALL ON TABLE "public"."stg_dimstaff" TO "authenticated";
GRANT ALL ON TABLE "public"."stg_dimstaff" TO "service_role";



GRANT ALL ON TABLE "public"."stg_salesdailysheets" TO "anon";
GRANT ALL ON TABLE "public"."stg_salesdailysheets" TO "authenticated";
GRANT ALL ON TABLE "public"."stg_salesdailysheets" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_summary" TO "anon";
GRANT ALL ON TABLE "public"."v_admin_payroll_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."v_admin_payroll_summary" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_summary_by_location" TO "anon";
GRANT ALL ON TABLE "public"."v_admin_payroll_summary_by_location" TO "authenticated";
GRANT ALL ON TABLE "public"."v_admin_payroll_summary_by_location" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_payroll_summary_by_stylist" TO "anon";
GRANT ALL ON TABLE "public"."v_admin_payroll_summary_by_stylist" TO "authenticated";
GRANT ALL ON TABLE "public"."v_admin_payroll_summary_by_stylist" TO "service_role";



GRANT ALL ON TABLE "public"."v_admin_user_access_overview" TO "service_role";



GRANT ALL ON TABLE "public"."v_sales_transactions_enriched" TO "anon";
GRANT ALL ON TABLE "public"."v_sales_transactions_enriched" TO "authenticated";
GRANT ALL ON TABLE "public"."v_sales_transactions_enriched" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_lines_secure" TO "anon";
GRANT ALL ON TABLE "public"."v_stylist_commission_lines_secure" TO "authenticated";
GRANT ALL ON TABLE "public"."v_stylist_commission_lines_secure" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_lines_access_scoped" TO "anon";
GRANT ALL ON TABLE "public"."v_stylist_commission_lines_access_scoped" TO "authenticated";
GRANT ALL ON TABLE "public"."v_stylist_commission_lines_access_scoped" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_lines_final" TO "anon";
GRANT ALL ON TABLE "public"."v_stylist_commission_lines_final" TO "authenticated";
GRANT ALL ON TABLE "public"."v_stylist_commission_lines_final" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_summary_secure" TO "anon";
GRANT ALL ON TABLE "public"."v_stylist_commission_summary_secure" TO "authenticated";
GRANT ALL ON TABLE "public"."v_stylist_commission_summary_secure" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_summary_self_service" TO "anon";
GRANT ALL ON TABLE "public"."v_stylist_commission_summary_self_service" TO "authenticated";
GRANT ALL ON TABLE "public"."v_stylist_commission_summary_self_service" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_summary_access_scoped" TO "anon";
GRANT ALL ON TABLE "public"."v_stylist_commission_summary_access_scoped" TO "authenticated";
GRANT ALL ON TABLE "public"."v_stylist_commission_summary_access_scoped" TO "service_role";



GRANT ALL ON TABLE "public"."v_stylist_commission_summary_final" TO "anon";
GRANT ALL ON TABLE "public"."v_stylist_commission_summary_final" TO "authenticated";
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































