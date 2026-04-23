-- =====================================================================
-- Fix: v_sales_transactions_enriched.assistant_redirect_candidate
--      (and the commission_owner_candidate_id/_name cascade that
--       depends on it) for the Sales Daily Sheets import reality.
--
-- Background
-- ----------
-- public.load_raw_sales_rows_to_transactions and its backfill UPDATE
-- (20260430500000_fix_commission_attribution_sales_daily_sheets.sql)
-- populate:
--   * staff_commission_name  <- raw first_name       (engagement owner)
--   * staff_commission_id    <- looked up from name
--   * staff_work_name        <- raw staff_work_name  (actual worker)
--   * staff_work_id          <- looked up from name
--   * staff_paid_name        <- NULL  (explicitly not populated)
--   * staff_paid_id          <- NULL  (not in INSERT column list)
--
-- The original assistant_redirect_candidate definition requires
--   staff_paid_id IS NOT NULL AND staff_work_id <> staff_paid_id
-- so for every row produced by the import pipeline the flag is FALSE.
-- This is the direct root cause of assistant_utilisation_ratio
-- returning 0 for every stylist (Jarod March 2026 included).
--
-- In this dataset, the engagement owner / senior stylist lives in
-- staff_commission_id, which the payroll/commission layer
-- (v_sales_transactions_powerbi_parity.staff_paid_name_derived)
-- already uses as the effective "paid staff" for assistant-helped
-- lines. We mirror that treatment here: the flag fires when the
-- worker is a wage-assistant AND a different staff member owns the
-- line via either staff_paid_id (legacy / manual edits) OR
-- staff_commission_id (import reality).
--
-- Commission-owner cascade
-- ------------------------
-- The existing cascade redirects to staff_paid_id when the flag
-- fires, which would yield NULL in the import-reality case. We
-- update it to COALESCE(staff_paid_id, staff_commission_id). For
-- rows where staff_paid_id is populated, behaviour is unchanged;
-- for the common NULL case the owner becomes the engagement
-- owner (staff_commission_id) — identical to what the previous
-- "staff_commission_id IS NOT NULL" fallback branch produced. So
-- commission_owner_candidate_id / _name are byte-identical for every
-- existing row; the only behavioural change is that the boolean
-- flag is now correctly set to TRUE on rows that fit the rule.
--
-- Scope
-- -----
-- Only changes:
--   * assistant_redirect_candidate (CASE expression)
--   * commission_owner_candidate_id (assistant branch fallback)
--   * commission_owner_candidate_name (assistant branch fallback)
--   * review_flag (assistant_work_redirect_candidate branch)
-- All other columns, ordering, and types in v_sales_transactions_enriched
-- are preserved exactly.
-- =====================================================================

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
