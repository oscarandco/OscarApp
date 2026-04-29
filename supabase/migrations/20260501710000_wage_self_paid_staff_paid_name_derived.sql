-- Wage + self-paid parity: `staff_paid_name_derived` was NULL for wage staff when work = paid
-- (after 20260431500000) because `WHEN work_remuneration_plan = wage THEN NULL` ran before ELSE
-- `staff_work_name`, so `no_paid_staff_derived` + null `derived_staff_paid_id` despite DAX parity Yes.
-- Inserts a branch: when staff_work_is_staff_paid = Yes OR commission/work names match (non-internal),
-- derive paid from work_display_name / staff_work_name. Extends sm_paid join by staff_work_id when
-- parity Yes and derived name still null (ID fallback). Copies 20260501680000 reporting views unchanged otherwise.

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
            COALESCE("sc"."display_name", NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text")) AS "commission_display_name",
            COALESCE("sc"."full_name", NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text")) AS "commission_full_name",
            "sc"."primary_role" AS "commission_primary_role",
            "sc"."remuneration_plan" AS "commission_remuneration_plan",
            "sc"."employment_type" AS "commission_employment_type",
            COALESCE("sw"."display_name", NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text"), NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text")) AS "work_display_name",
            COALESCE("sw"."full_name", NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text"), NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text")) AS "work_full_name",
            "sw"."primary_role" AS "work_primary_role",
            "sw"."remuneration_plan" AS "work_remuneration_plan",
            "sw"."employment_type" AS "work_employment_type",
            "rp"."plan_name" AS "commission_plan_name",
            "rp"."can_use_assistants" AS "commission_can_use_assistants"
           FROM ("public"."sales_transactions" "st"
             LEFT JOIN "public"."product_master" "pm" ON (("lower"(TRIM(BOTH FROM "st"."product_service_name")) = "lower"(TRIM(BOTH FROM "pm"."product_description"))))
             LEFT JOIN LATERAL (
                 SELECT "sm".*
                 FROM "public"."staff_members" "sm"
                 WHERE (("st"."staff_commission_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_commission_id"))
                    OR (("st"."staff_commission_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text") IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "st"."staff_commission_name")) = "lower"(TRIM(BOTH FROM "sm"."display_name"))) AND ("sm"."is_active" = true))
                 ORDER BY
                     CASE
                         WHEN (("st"."staff_commission_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_commission_id")) THEN 0
                         ELSE 1
                     END
                 LIMIT 1
             ) "sc" ON (true)
             LEFT JOIN LATERAL (
                 SELECT "sm".*
                 FROM "public"."staff_members" "sm"
                 WHERE (("st"."staff_work_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_work_id"))
                    OR (("st"."staff_work_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text") IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "st"."staff_work_name")) = "lower"(TRIM(BOTH FROM "sm"."display_name"))) AND ("sm"."is_active" = true))
                 ORDER BY
                     CASE
                         WHEN (("st"."staff_work_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_work_id")) THEN 0
                         ELSE 1
                     END
                 LIMIT 1
             ) "sw" ON (true)
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
                    WHEN (
                      ("upper"(TRIM(BOTH FROM COALESCE("b"."work_primary_role", ''::"text"))) <> 'INTERNAL'::"text")
                      AND (
                        lower(TRIM(BOTH FROM COALESCE("b"."staff_work_is_staff_paid", ''::"text"))) = 'yes'::"text"
                        OR (
                          NULLIF(TRIM(BOTH FROM COALESCE("b"."staff_work_name", ''::"text")), ''::"text") IS NOT NULL
                          AND lower(TRIM(BOTH FROM COALESCE("b"."staff_commission_name", ''::"text")))
                            = lower(TRIM(BOTH FROM COALESCE("b"."staff_work_name", ''::"text")))
                        )
                      )
                    )
                    THEN COALESCE(
                      NULLIF(TRIM(BOTH FROM COALESCE("b"."work_display_name", ''::"text")), ''::"text"),
                      NULLIF(TRIM(BOTH FROM COALESCE("b"."staff_work_name", ''::"text")), ''::"text")
                    )
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
            COALESCE(
              "sm_paid"."display_name",
              NULLIF(TRIM(BOTH FROM COALESCE("p"."staff_paid_name_derived", ''::"text")), ''::"text"),
              NULLIF(TRIM(BOTH FROM COALESCE("p"."existing_staff_paid_name", ''::"text")), ''::"text"),
              NULLIF(TRIM(BOTH FROM COALESCE("p"."staff_commission_name", ''::"text")), ''::"text"),
              NULLIF(TRIM(BOTH FROM COALESCE("p"."staff_work_name", ''::"text")), ''::"text")
            ) AS "derived_staff_paid_display_name",
            COALESCE(
              "sm_paid"."full_name",
              NULLIF(TRIM(BOTH FROM COALESCE("p"."staff_paid_name_derived", ''::"text")), ''::"text"),
              NULLIF(TRIM(BOTH FROM COALESCE("p"."existing_staff_paid_name", ''::"text")), ''::"text"),
              NULLIF(TRIM(BOTH FROM COALESCE("p"."staff_commission_name", ''::"text")), ''::"text"),
              NULLIF(TRIM(BOTH FROM COALESCE("p"."staff_work_name", ''::"text")), ''::"text")
            ) AS "derived_staff_paid_full_name",
            "sm_paid"."primary_role" AS "derived_staff_paid_primary_role",
            "sm_paid"."remuneration_plan" AS "derived_staff_paid_remuneration_plan",
            "sm_paid"."employment_type" AS "derived_staff_paid_employment_type",
            "rp_paid"."id" AS "derived_staff_paid_plan_id",
            "rp_paid"."plan_name" AS "derived_staff_paid_plan_name",
            "rp_commission"."id" AS "benchmark_commission_plan_id",
            "rp_commission"."plan_name" AS "benchmark_commission_plan_name"
           FROM ((("parity" "p"
             LEFT JOIN "public"."staff_members" "sm_paid" ON ((
              (("p"."staff_paid_name_derived" IS NOT NULL)
                AND ("lower"(TRIM(BOTH FROM "p"."staff_paid_name_derived")) = "lower"(TRIM(BOTH FROM "sm_paid"."display_name"))))
              OR (
                "p"."staff_paid_name_derived" IS NULL
                AND "p"."staff_work_id" IS NOT NULL
                AND "p"."staff_work_is_staff_paid_dax_parity" = 'Yes'::"text"
                AND "sm_paid"."id" = "p"."staff_work_id"
              )
            ))))
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
            COALESCE("sw"."display_name", NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text"), NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text")) AS "staff_work_display_name",
            COALESCE("sw"."full_name", NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text"), NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text")) AS "staff_work_full_name",
            "sw"."primary_role" AS "staff_work_primary_role",
            "sw"."remuneration_plan" AS "staff_work_remuneration_plan",
            "sw"."employment_type" AS "staff_work_employment_type",
            "sw"."is_active" AS "staff_work_is_active",
            COALESCE("sp"."display_name", NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_paid_name", ''::"text")), ''::"text"), NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text"), NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text")) AS "staff_paid_display_name",
            COALESCE("sp"."full_name", NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_paid_name", ''::"text")), ''::"text"), NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text"), NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text")) AS "staff_paid_full_name",
            "sp"."primary_role" AS "staff_paid_primary_role",
            "sp"."remuneration_plan" AS "staff_paid_remuneration_plan",
            "sp"."employment_type" AS "staff_paid_employment_type",
            "sp"."is_active" AS "staff_paid_is_active",
            COALESCE("sc"."display_name", NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text"), NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text")) AS "staff_commission_display_name",
            COALESCE("sc"."full_name", NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text"), NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text")) AS "staff_commission_full_name",
            "sc"."primary_role" AS "staff_commission_primary_role",
            "sc"."remuneration_plan" AS "staff_commission_remuneration_plan",
            "sc"."employment_type" AS "staff_commission_employment_type",
            "sc"."is_active" AS "staff_commission_is_active",
            "st"."created_at",
            "st"."updated_at"
           FROM ("public"."sales_transactions" "st"
             LEFT JOIN LATERAL (
                 SELECT "sm".*
                 FROM "public"."staff_members" "sm"
                 WHERE (("st"."staff_work_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_work_id"))
                    OR (("st"."staff_work_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_work_name", ''::"text")), ''::"text") IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "st"."staff_work_name")) = "lower"(TRIM(BOTH FROM "sm"."display_name"))) AND ("sm"."is_active" = true))
                 ORDER BY
                     CASE
                         WHEN (("st"."staff_work_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_work_id")) THEN 0
                         ELSE 1
                     END
                 LIMIT 1
             ) "sw" ON (true)
             LEFT JOIN LATERAL (
                 SELECT "sm".*
                 FROM "public"."staff_members" "sm"
                 WHERE (("st"."staff_paid_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_paid_id"))
                    OR (("st"."staff_paid_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_paid_name", ''::"text")), ''::"text") IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "st"."staff_paid_name")) = "lower"(TRIM(BOTH FROM "sm"."display_name"))) AND ("sm"."is_active" = true))
                 ORDER BY
                     CASE
                         WHEN (("st"."staff_paid_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_paid_id")) THEN 0
                         ELSE 1
                     END
                 LIMIT 1
             ) "sp" ON (true)
             LEFT JOIN LATERAL (
                 SELECT "sm".*
                 FROM "public"."staff_members" "sm"
                 WHERE (("st"."staff_commission_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_commission_id"))
                    OR (("st"."staff_commission_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("st"."staff_commission_name", ''::"text")), ''::"text") IS NOT NULL) AND ("lower"(TRIM(BOTH FROM "st"."staff_commission_name")) = "lower"(TRIM(BOTH FROM "sm"."display_name"))) AND ("sm"."is_active" = true))
                 ORDER BY
                     CASE
                         WHEN (("st"."staff_commission_id" IS NOT NULL) AND ("sm"."id" = "st"."staff_commission_id")) THEN 0
                         ELSE 1
                     END
                 LIMIT 1
             ) "sc" ON (true)
           )
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
                -- assistant_redirect_candidate: wage-based assistant did
                -- the work for a different staff member who owns the line.
                -- The "different owner" is staff_paid_id when populated
                -- (legacy / manual edits) or staff_commission_id (the
                -- engagement owner recorded by the import pipeline).
                CASE
                    WHEN (
                      ("b"."staff_work_id" IS NOT NULL)
                      AND (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_work_primary_role")), ''::"text") = 'assistant'::"text")
                      AND (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_work_remuneration_plan")), ''::"text") = 'wage'::"text")
                      AND (
                            (("b"."staff_paid_id" IS NOT NULL) AND ("b"."staff_work_id" <> "b"."staff_paid_id"))
                         OR (("b"."staff_paid_id" IS NULL) AND ("b"."staff_commission_id" IS NOT NULL) AND ("b"."staff_work_id" <> "b"."staff_commission_id"))
                      )
                    ) THEN true
                    ELSE false
                END AS "assistant_redirect_candidate",
                CASE
                    WHEN (("b"."staff_work_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("b"."staff_work_name", ''::"text")), ''::"text") IS NOT NULL)) THEN 'unmatched_work_staff'::"text"
                    WHEN (("b"."staff_paid_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("b"."staff_paid_name", ''::"text")), ''::"text") IS NOT NULL)) THEN 'unmatched_paid_staff'::"text"
                    WHEN (("b"."staff_commission_id" IS NULL) AND (NULLIF(TRIM(BOTH FROM COALESCE("b"."staff_commission_name", ''::"text")), ''::"text") IS NOT NULL)) THEN 'unmatched_commission_staff'::"text"
                    WHEN (
                      ("b"."staff_work_id" IS NOT NULL)
                      AND (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_work_primary_role")), ''::"text") = 'assistant'::"text")
                      AND (COALESCE("lower"(TRIM(BOTH FROM "b"."staff_work_remuneration_plan")), ''::"text") = 'wage'::"text")
                      AND (
                            (("b"."staff_paid_id" IS NOT NULL) AND ("b"."staff_work_id" <> "b"."staff_paid_id"))
                         OR (("b"."staff_paid_id" IS NULL) AND ("b"."staff_commission_id" IS NOT NULL) AND ("b"."staff_work_id" <> "b"."staff_commission_id"))
                      )
                    ) THEN 'assistant_work_redirect_candidate'::"text"
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
        -- Commission owner cascade: when assistant_redirect_candidate
        -- fires, prefer staff_paid_id but fall back to
        -- staff_commission_id (the import-populated engagement owner).
        -- For existing rows the fallback is identical to what the
        -- previous "staff_commission_id IS NOT NULL" branch produced,
        -- so no existing commission_owner_candidate_id / _name value
        -- changes.
        CASE
            WHEN "assistant_redirect_candidate" THEN COALESCE("staff_paid_id", "staff_commission_id")
            WHEN ("staff_commission_id" IS NOT NULL) THEN "staff_commission_id"
            WHEN ("staff_paid_id" IS NOT NULL) THEN "staff_paid_id"
            ELSE "staff_work_id"
        END AS "commission_owner_candidate_id",
        CASE
            WHEN "assistant_redirect_candidate" THEN COALESCE("staff_paid_display_name", "staff_commission_display_name")
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
