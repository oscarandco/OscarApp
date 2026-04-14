-- Remove creative_director commission category: data, CHECK constraint, staging column,
-- and product_header mapping in v_sales_transactions_powerbi_parity.

DELETE FROM public.remuneration_plan_rates
WHERE commission_category = 'creative_director';

ALTER TABLE public.remuneration_plan_rates
  DROP CONSTRAINT IF EXISTS remuneration_plan_rates_category_valid;

ALTER TABLE public.remuneration_plan_rates
  ADD CONSTRAINT remuneration_plan_rates_category_valid CHECK (
    commission_category = ANY (
      ARRAY[
        'retail_product',
        'professional_product',
        'service',
        'voucher',
        'toner_with_other_service',
        'extensions_product',
        'extensions_service'
      ]::text[]
    )
  );

ALTER TABLE public.stg_dimremunerationplans
  DROP COLUMN IF EXISTS creative_director;

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


ALTER VIEW public.v_sales_transactions_powerbi_parity OWNER TO postgres;
