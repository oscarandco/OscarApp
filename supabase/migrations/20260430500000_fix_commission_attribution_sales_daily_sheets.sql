-- Commission attribution (Sales Daily Sheets):
-- FIRST_NAME -> staff_commission_name (engagement owner), NAME -> staff_work_name (worker).
-- staff_paid_name is not populated from import (derived downstream only).
--
-- Objects: load_raw_sales_rows_to_transactions, backfill UPDATE,
--          v_sales_transactions_powerbi_parity, v_sales_transactions_enriched.

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


-- Backfill sales_transactions from raw import rows (repair historical rows).

UPDATE public.sales_transactions st
SET
  staff_commission_name = NULLIF(TRIM(r.first_name), ''),
  staff_work_name = NULLIF(TRIM(r.staff_work_name), ''),
  staff_paid_name = NULL,
  staff_paid_id = NULL,
  staff_commission_id = (
    SELECT sm.id
    FROM public.staff_members sm
    WHERE NULLIF(TRIM(r.first_name), '') IS NOT NULL
      AND LOWER(TRIM(sm.display_name)) = LOWER(TRIM(r.first_name))
      AND sm.is_active = true
    LIMIT 1
  ),
  staff_work_id = (
    SELECT sm.id
    FROM public.staff_members sm
    WHERE NULLIF(TRIM(r.staff_work_name), '') IS NOT NULL
      AND LOWER(TRIM(sm.display_name)) = LOWER(TRIM(r.staff_work_name))
      AND sm.is_active = true
    LIMIT 1
  ),
  staff_work_is_staff_paid = CASE
    WHEN NULLIF(TRIM(r.staff_work_name), '') IS NOT NULL
      AND NULLIF(TRIM(r.first_name), '') IS NOT NULL
      AND LOWER(TRIM(r.staff_work_name)) = LOWER(TRIM(r.first_name)) THEN 'Yes'
    ELSE 'No'
  END,
  product_header = COALESCE(r.description, '') || ' | ' || COALESCE(r.staff_work_name, ''),
  updated_at = now()
FROM public.raw_sales_import_rows r
WHERE st.raw_row_id = r.id;


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


-- Validation (run manually after migrate):
--
-- 1) Invoice INV95545 — expect staff_commission_name = engagement owner, staff_work_name = worker,
--    staff_paid_name_derived = commission owner when assistant + can_use_assistants.
-- SELECT st.invoice, st.staff_commission_name, st.staff_work_name, st.staff_paid_name,
--        p.work_primary_role, p.commission_plan_name, p.commission_can_use_assistants,
--        p.staff_paid_name_derived, c.derived_staff_paid_display_name, c.actual_commission_rate
-- FROM public.sales_transactions st
-- JOIN public.v_sales_transactions_powerbi_parity p ON p.id = st.id
-- JOIN public.v_commission_calculations_core c ON c.id = st.id
-- WHERE st.invoice = 'INV95545';
--
-- 2) Assistant rows (work = Assistant, commission owner = Senior Stylist on Commission plan with can_use_assistants):
--    staff_paid_name_derived should equal staff_commission_name; derived_staff_paid_id should match owner.
-- SELECT st.invoice, st.staff_commission_name, st.staff_work_name,
--        p.work_primary_role, p.staff_paid_name_derived, c.derived_staff_paid_display_name, c.calculation_alert
-- FROM public.sales_transactions st
-- JOIN public.v_sales_transactions_powerbi_parity p ON p.id = st.id
-- JOIN public.v_commission_calculations_core c ON c.id = st.id
-- WHERE upper(trim(coalesce(p.work_primary_role,''))) = 'ASSISTANT'
-- LIMIT 50;
