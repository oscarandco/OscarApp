-- Theoretical (potential) assistant commission, authored in the commission
-- engine (v_commission_calculations_core) and propagated through the same
-- reporting pipeline used by payroll and My Sales.
--
-- Why this exists
-- ---------------
-- v_commission_calculations_core already computes three line-level
-- commission amounts:
--   * actual_commission_amt_ex_gst       (price_ex_gst * actual_commission_rate,
--                                          for the paid stylist on their own plan)
--   * theoretical_commission_amt_ex_gst  (price_ex_gst * theoretical_commission_rate,
--                                          i.e. what the paid stylist WOULD have
--                                          earned on the benchmark Commission plan)
--   * assistant_commission_amt_ex_gst    (price_ex_gst * actual_commission_rate
--                                          when the work staff is an Assistant
--                                          and the paid stylist's plan
--                                          can_use_assistants - i.e. ACTUAL
--                                          assistant commission paid out)
--
-- There was no field for "what assistant commission WOULD have applied to
-- assistant work for this stylist if their plan was the benchmark Commission
-- plan". For wage stylists (Leah etc.) that value is non-zero and useful;
-- their actual assistant commission is usually 0 because wage plans don't
-- have a commission rate (so the existing actual_commission_rate gate fires).
--
-- This migration adds:
--   * v_commission_calculations_core.theoretical_assistant_commission_amt_ex_gst
--       = price_ex_gst * theoretical_commission_rate
--         WHEN the work staff is an Assistant
--          AND the benchmark Commission plan supports assistants
--          AND price / theoretical rate are populated.
--       Otherwise NULL (and 0 if paid staff is named but unconfigured,
--       matching the existing theoretical_commission_amt_ex_gst clause).
--     This is a 1:1 structural mirror of the existing actual-side formula
--     with (a) actual_commission_rate swapped for theoretical_commission_rate
--     and (b) the paid stylist's can_use_assistants flag swapped for the
--     benchmark Commission plan's can_use_assistants flag.
--   * Passthrough through v_commission_calculations_qa and
--     v_admin_payroll_lines. The new column is APPENDED at the end of
--     each view to satisfy CREATE OR REPLACE VIEW's column-shape rule
--     (existing columns must stay in their existing positions; new
--     columns may only be added at the end).
--   * v_admin_payroll_lines_weekly is re-stated with an explicit column
--     list (preserving the existing column order from the previous
--     SELECT l.*, synthetic-columns form) so the new column can be
--     appended at the end without shifting any existing position.
--   * get_my_sales_trend_weekly DROP + CREATE to add
--     total_theoretical_assistant_commission_ex_gst
--       = ROUND(SUM(COALESCE(theoretical_assistant_commission_amt_ex_gst, 0)), 2)
--     to the returned table. Pure pass-through sum of the trusted
--     upstream column; no second calculation path.
--
-- Not touched (deliberate)
-- ------------------------
--   * actual_commission_amt_ex_gst, theoretical_commission_amt_ex_gst,
--     assistant_commission_amt_ex_gst formulas. Byte-for-byte identical
--     to the previous Phase 2 view definition.
--   * v_admin_payroll_summary_weekly. Admin Sales summary feed. Its
--     explicit column list does not reference the new column, so the
--     Sales summary RPC, KPI cards and weekly summary table all see
--     exactly the same numbers as before.
--   * v_stylist_commission_lines_* / My Sales line preview RPC route.
--   * KPI RPCs (stylist profitability, comparisons, leaders, revenue,
--     guests, new_clients, avg spend, assistant utilisation, snapshot).
--   * Contractor invoice RPCs (preview / batch / create / void / list).
--   * Voucher exclusion logic (public.is_voucher_sale_row).
--   * Product classification (product_type_actual_derived /
--     product_type_short_derived / commission_product_service_derived).
--   * Role / pay history (public.staff_role_assignments,
--     public.staff_profile_at, trigger / Staff Admin UI).


-- ===========================================================================
-- 1. v_commission_calculations_core (REPLACED)
--
--    paid_staff_resolved exposes rp_commission.can_use_assistants as
--    benchmark_commission_can_use_assistants so the new theoretical
--    assistant clause has a faithful eligibility flag (mirrors the actual
--    side, which uses the paid stylist's own commission_can_use_assistants).
--
--    rated passes that flag through.
--
--    Final SELECT appends theoretical_assistant_commission_amt_ex_gst at
--    the end so CREATE OR REPLACE preserves the existing column shape.
-- ===========================================================================
CREATE OR REPLACE VIEW public.v_commission_calculations_core AS
WITH parity AS (
  SELECT
    v.id, v.import_batch_id, v.raw_row_id, v.location_id, v.invoice,
    v.customer_name, v.sale_datetime, v.sale_date, v.day_name, v.month_start,
    v.month_num, v.product_service_name, v.product_master_id, v.raw_product_type,
    v.existing_product_type_actual, v.existing_product_type_short,
    v.existing_commission_product_service, v.quantity, v.price_ex_gst,
    v.price_incl_gst, v.price_gst_component, v.staff_commission_name,
    v.staff_work_name, v.existing_staff_paid_name, v.staff_commission_id,
    v.staff_work_id, v.staff_paid_id, v.staff_commission_type,
    v.staff_work_type, v.staff_paid_type, v.existing_assistant_usage_alert,
    v.staff_work_is_staff_paid, v.invoice_header, v.product_header,
    v.created_at, v.updated_at, v.master_product_description, v.master_product_type,
    v.commission_display_name, v.commission_full_name, v.commission_primary_role,
    v.commission_remuneration_plan, v.commission_employment_type,
    v.work_display_name, v.work_full_name, v.work_primary_role,
    v.work_remuneration_plan, v.work_employment_type, v.commission_plan_name,
    v.commission_can_use_assistants, v.product_type_actual_derived,
    v.product_type_short_derived, v.commission_product_service_derived,
    v.staff_paid_name_derived, v.assistant_usage_alert_derived,
    v.staff_work_is_staff_paid_dax_parity, v.commission_category_final
  FROM public.v_sales_transactions_powerbi_parity v
),
paid_staff_resolved AS (
  SELECT
    p.id, p.import_batch_id, p.raw_row_id, p.location_id, p.invoice,
    p.customer_name, p.sale_datetime, p.sale_date, p.day_name, p.month_start,
    p.month_num, p.product_service_name, p.product_master_id, p.raw_product_type,
    p.existing_product_type_actual, p.existing_product_type_short,
    p.existing_commission_product_service, p.quantity, p.price_ex_gst,
    p.price_incl_gst, p.price_gst_component, p.staff_commission_name,
    p.staff_work_name, p.existing_staff_paid_name, p.staff_commission_id,
    p.staff_work_id, p.staff_paid_id, p.staff_commission_type,
    p.staff_work_type, p.staff_paid_type, p.existing_assistant_usage_alert,
    p.staff_work_is_staff_paid, p.invoice_header, p.product_header,
    p.created_at, p.updated_at, p.master_product_description, p.master_product_type,
    p.commission_display_name, p.commission_full_name, p.commission_primary_role,
    p.commission_remuneration_plan, p.commission_employment_type,
    p.work_display_name, p.work_full_name, p.work_primary_role,
    p.work_remuneration_plan, p.work_employment_type, p.commission_plan_name,
    p.commission_can_use_assistants, p.product_type_actual_derived,
    p.product_type_short_derived, p.commission_product_service_derived,
    p.staff_paid_name_derived, p.assistant_usage_alert_derived,
    p.staff_work_is_staff_paid_dax_parity, p.commission_category_final,
    sm_paid.id AS derived_staff_paid_id,
    COALESCE(
      sm_paid.display_name,
      NULLIF(TRIM(COALESCE(p.staff_paid_name_derived, '')), ''),
      NULLIF(TRIM(COALESCE(p.existing_staff_paid_name, '')), ''),
      NULLIF(TRIM(COALESCE(p.staff_commission_name, '')), ''),
      NULLIF(TRIM(COALESCE(p.staff_work_name, '')), '')
    ) AS derived_staff_paid_display_name,
    COALESCE(
      sm_paid.full_name,
      NULLIF(TRIM(COALESCE(p.staff_paid_name_derived, '')), ''),
      NULLIF(TRIM(COALESCE(p.existing_staff_paid_name, '')), ''),
      NULLIF(TRIM(COALESCE(p.staff_commission_name, '')), ''),
      NULLIF(TRIM(COALESCE(p.staff_work_name, '')), '')
    ) AS derived_staff_paid_full_name,
    COALESCE(sm_paid_eff.primary_role,      sm_paid.primary_role)      AS derived_staff_paid_primary_role,
    COALESCE(sm_paid_eff.remuneration_plan, sm_paid.remuneration_plan) AS derived_staff_paid_remuneration_plan,
    COALESCE(sm_paid_eff.employment_type,   sm_paid.employment_type)   AS derived_staff_paid_employment_type,
    rp_paid.id        AS derived_staff_paid_plan_id,
    rp_paid.plan_name AS derived_staff_paid_plan_name,
    rp_commission.id                AS benchmark_commission_plan_id,
    rp_commission.plan_name         AS benchmark_commission_plan_name,
    -- NEW: benchmark Commission plan's can_use_assistants flag. Internal
    -- to this view; used only by the new theoretical_assistant_commission
    -- CASE in the final SELECT. NULL if rp_commission is missing.
    rp_commission.can_use_assistants AS benchmark_commission_can_use_assistants
  FROM parity p
    LEFT JOIN public.staff_members sm_paid ON (
      (p.staff_paid_name_derived IS NOT NULL
       AND lower(TRIM(p.staff_paid_name_derived)) = lower(TRIM(sm_paid.display_name)))
      OR (p.staff_paid_name_derived IS NULL
          AND p.staff_work_id IS NOT NULL
          AND p.staff_work_is_staff_paid_dax_parity = 'Yes'
          AND sm_paid.id = p.staff_work_id)
    )
    LEFT JOIN LATERAL public.staff_profile_at(sm_paid.id, p.sale_date) sm_paid_eff
      ON true
    LEFT JOIN public.remuneration_plans rp_paid ON (
      COALESCE(sm_paid_eff.remuneration_plan, sm_paid.remuneration_plan) IS NOT NULL
      AND lower(TRIM(COALESCE(sm_paid_eff.remuneration_plan, sm_paid.remuneration_plan)))
          = lower(TRIM(rp_paid.plan_name))
    )
    LEFT JOIN public.remuneration_plans rp_commission
      ON lower(TRIM(rp_commission.plan_name)) = 'commission'
),
rated AS (
  SELECT
    psr.id, psr.import_batch_id, psr.raw_row_id, psr.location_id, psr.invoice,
    psr.customer_name, psr.sale_datetime, psr.sale_date, psr.day_name,
    psr.month_start, psr.month_num, psr.product_service_name,
    psr.product_master_id, psr.raw_product_type, psr.existing_product_type_actual,
    psr.existing_product_type_short, psr.existing_commission_product_service,
    psr.quantity, psr.price_ex_gst, psr.price_incl_gst, psr.price_gst_component,
    psr.staff_commission_name, psr.staff_work_name, psr.existing_staff_paid_name,
    psr.staff_commission_id, psr.staff_work_id, psr.staff_paid_id,
    psr.staff_commission_type, psr.staff_work_type, psr.staff_paid_type,
    psr.existing_assistant_usage_alert, psr.staff_work_is_staff_paid,
    psr.invoice_header, psr.product_header, psr.created_at, psr.updated_at,
    psr.master_product_description, psr.master_product_type,
    psr.commission_display_name, psr.commission_full_name,
    psr.commission_primary_role, psr.commission_remuneration_plan,
    psr.commission_employment_type, psr.work_display_name, psr.work_full_name,
    psr.work_primary_role, psr.work_remuneration_plan, psr.work_employment_type,
    psr.commission_plan_name, psr.commission_can_use_assistants,
    psr.product_type_actual_derived, psr.product_type_short_derived,
    psr.commission_product_service_derived, psr.staff_paid_name_derived,
    psr.assistant_usage_alert_derived, psr.staff_work_is_staff_paid_dax_parity,
    psr.commission_category_final, psr.derived_staff_paid_id,
    psr.derived_staff_paid_display_name, psr.derived_staff_paid_full_name,
    psr.derived_staff_paid_primary_role, psr.derived_staff_paid_remuneration_plan,
    psr.derived_staff_paid_employment_type, psr.derived_staff_paid_plan_id,
    psr.derived_staff_paid_plan_name, psr.benchmark_commission_plan_id,
    psr.benchmark_commission_plan_name,
    psr.benchmark_commission_can_use_assistants,
    apr.rate AS actual_commission_rate,
    tpr.rate AS theoretical_commission_rate
  FROM paid_staff_resolved psr
    LEFT JOIN public.remuneration_plan_rates apr
      ON apr.remuneration_plan_id = psr.derived_staff_paid_plan_id
     AND lower(TRIM(apr.commission_category)) = lower(TRIM(psr.commission_category_final))
    LEFT JOIN public.remuneration_plan_rates tpr
      ON tpr.remuneration_plan_id = psr.benchmark_commission_plan_id
     AND lower(TRIM(tpr.commission_category)) = lower(TRIM(psr.commission_category_final))
)
SELECT
  id, import_batch_id, raw_row_id, location_id, invoice, customer_name,
  sale_datetime, sale_date, day_name, month_start, month_num,
  product_service_name, product_master_id, master_product_description,
  master_product_type, raw_product_type, product_type_actual_derived,
  product_type_short_derived, commission_product_service_derived,
  commission_category_final, quantity, price_ex_gst, price_incl_gst,
  price_gst_component, staff_commission_name, staff_work_name,
  existing_staff_paid_name, staff_paid_name_derived, staff_commission_id,
  staff_work_id, staff_paid_id AS existing_staff_paid_id,
  derived_staff_paid_id, commission_display_name, commission_full_name,
  commission_primary_role, commission_remuneration_plan, work_display_name,
  work_full_name, work_primary_role, work_remuneration_plan,
  derived_staff_paid_display_name, derived_staff_paid_full_name,
  derived_staff_paid_primary_role, derived_staff_paid_remuneration_plan,
  derived_staff_paid_employment_type, derived_staff_paid_plan_id,
  derived_staff_paid_plan_name, commission_can_use_assistants,
  assistant_usage_alert_derived, staff_work_is_staff_paid_dax_parity,
  CASE
    WHEN lower(TRIM(COALESCE(staff_paid_name_derived, ''))) = 'internal' THEN true
    ELSE false
  END AS is_internal_non_commission,
  CASE
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = ANY (
      ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text,
            'no_commission_trainingproduct'::text,
            'no_commission_miscellaneousproduct'::text,
            'no_commission_voucher'::text, 'no_commission_unclassified'::text]
    ) THEN true
    ELSE false
  END AS is_named_non_commission_category,
  actual_commission_rate,
  CASE
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = ANY (
      ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text,
            'no_commission_trainingproduct'::text,
            'no_commission_miscellaneousproduct'::text,
            'no_commission_voucher'::text, 'no_commission_unclassified'::text]
    ) THEN NULL::numeric
    WHEN (lower(TRIM(COALESCE(staff_paid_name_derived, ''))) <> 'internal')
     AND (staff_paid_name_derived IS NOT NULL)
     AND ((derived_staff_paid_id IS NULL) OR (derived_staff_paid_plan_id IS NULL))
      THEN 0::numeric
    WHEN (price_ex_gst IS NOT NULL) AND (actual_commission_rate IS NOT NULL)
      THEN price_ex_gst * actual_commission_rate
    ELSE NULL::numeric
  END AS actual_commission_amt_ex_gst,
  theoretical_commission_rate,
  CASE
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = ANY (
      ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text,
            'no_commission_trainingproduct'::text,
            'no_commission_miscellaneousproduct'::text,
            'no_commission_voucher'::text, 'no_commission_unclassified'::text]
    ) THEN NULL::numeric
    WHEN (lower(TRIM(COALESCE(staff_paid_name_derived, ''))) <> 'internal')
     AND (staff_paid_name_derived IS NOT NULL)
     AND ((derived_staff_paid_id IS NULL) OR (derived_staff_paid_plan_id IS NULL))
      THEN 0::numeric
    WHEN (price_ex_gst IS NOT NULL) AND (theoretical_commission_rate IS NOT NULL)
      THEN price_ex_gst * theoretical_commission_rate
    ELSE NULL::numeric
  END AS theoretical_commission_amt_ex_gst,
  CASE
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = ANY (
      ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text,
            'no_commission_trainingproduct'::text,
            'no_commission_miscellaneousproduct'::text,
            'no_commission_voucher'::text, 'no_commission_unclassified'::text]
    ) THEN NULL::numeric
    WHEN (lower(TRIM(COALESCE(staff_paid_name_derived, ''))) <> 'internal')
     AND (staff_paid_name_derived IS NOT NULL)
     AND ((derived_staff_paid_id IS NULL) OR (derived_staff_paid_plan_id IS NULL))
      THEN 0::numeric
    WHEN (upper(TRIM(COALESCE(work_primary_role, ''))) = 'ASSISTANT')
     AND (commission_can_use_assistants = true)
     AND (price_ex_gst IS NOT NULL)
     AND (actual_commission_rate IS NOT NULL)
      THEN price_ex_gst * actual_commission_rate
    ELSE NULL::numeric
  END AS assistant_commission_amt_ex_gst,
  CASE
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = 'no_commission_greenfee'              THEN 'no_commission_greenfee'::text
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = 'no_commission_redo'                  THEN 'no_commission_redo'::text
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = 'no_commission_trainingproduct'       THEN 'no_commission_trainingproduct'::text
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = 'no_commission_miscellaneousproduct'  THEN 'no_commission_miscellaneousproduct'::text
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = 'no_commission_voucher'               THEN 'no_commission_voucher'::text
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = 'no_commission_unclassified'          THEN 'no_commission_unclassified'::text
    WHEN lower(TRIM(COALESCE(staff_paid_name_derived, ''))) = 'internal'                              THEN 'non_commission_internal'::text
    WHEN (staff_paid_name_derived IS NULL)
     AND (assistant_usage_alert_derived = 'Ineligible assistant usage')                                THEN 'blocked_ineligible_assistant_usage'::text
    WHEN staff_paid_name_derived IS NULL                                                              THEN 'no_paid_staff_derived'::text
    WHEN (staff_paid_name_derived IS NOT NULL)
     AND ((derived_staff_paid_id IS NULL) OR (derived_staff_paid_plan_id IS NULL))                    THEN 'non_commission_unconfigured_paid_staff'::text
    WHEN commission_category_final IS NULL                                                             THEN 'commission_category_not_derived'::text
    WHEN actual_commission_rate IS NULL                                                                THEN 'commission_rate_not_found'::text
    ELSE NULL::text
  END AS calculation_alert,
  invoice_header,
  product_header,
  created_at,
  updated_at,
  -- NEW (column appended at END): potential / theoretical assistant
  -- commission. Mirrors the actual assistant clause above, with two
  -- substitutions:
  --   * actual_commission_rate           -> theoretical_commission_rate
  --   * commission_can_use_assistants    -> benchmark_commission_can_use_assistants
  -- Same no-commission category gate, same paid-staff-unconfigured -> 0
  -- gate as the existing theoretical_commission_amt_ex_gst clause, so a
  -- line that is "expected non commission" for the paid stylist is also
  -- "expected non commission" for the theoretical assistant calc. The
  -- benchmark Commission plan's can_use_assistants flag is COALESCEd to
  -- false: if the benchmark plan is missing for any reason, this falls
  -- back to NULL rather than guessing.
  CASE
    WHEN lower(TRIM(COALESCE(commission_category_final, ''))) = ANY (
      ARRAY['no_commission_greenfee'::text, 'no_commission_redo'::text,
            'no_commission_trainingproduct'::text,
            'no_commission_miscellaneousproduct'::text,
            'no_commission_voucher'::text, 'no_commission_unclassified'::text]
    ) THEN NULL::numeric
    WHEN (lower(TRIM(COALESCE(staff_paid_name_derived, ''))) <> 'internal')
     AND (staff_paid_name_derived IS NOT NULL)
     AND ((derived_staff_paid_id IS NULL) OR (derived_staff_paid_plan_id IS NULL))
      THEN 0::numeric
    WHEN (upper(TRIM(COALESCE(work_primary_role, ''))) = 'ASSISTANT')
     AND (COALESCE(benchmark_commission_can_use_assistants, false) = true)
     AND (price_ex_gst IS NOT NULL)
     AND (theoretical_commission_rate IS NOT NULL)
      THEN price_ex_gst * theoretical_commission_rate
    ELSE NULL::numeric
  END AS theoretical_assistant_commission_amt_ex_gst
FROM rated;

ALTER VIEW public.v_commission_calculations_core OWNER TO postgres;

COMMENT ON VIEW public.v_commission_calculations_core IS
  'Commission calculations core view. Phase 2 effective-dated role/plan via public.staff_profile_at preserved. Adds line-level theoretical_assistant_commission_amt_ex_gst = price_ex_gst * theoretical_commission_rate when work staff is Assistant and the benchmark Commission plan supports assistants (mirrors the existing assistant_commission_amt_ex_gst formula with the theoretical rate / benchmark plan flag substituted). Actual / theoretical / assistant commission formulas and the calculation_alert ladder are unchanged.';


-- ===========================================================================
-- 2. v_commission_calculations_qa (REPLACED)
--    Same explicit column list as before (qa_bucket / qa_priority at the
--    end), then the new theoretical_assistant_commission_amt_ex_gst is
--    appended last so the existing column shape is preserved.
-- ===========================================================================
CREATE OR REPLACE VIEW public.v_commission_calculations_qa AS
SELECT
  c.id,
  c.import_batch_id,
  c.raw_row_id,
  c.location_id,
  c.invoice,
  c.customer_name,
  c.sale_datetime,
  c.sale_date,
  c.day_name,
  c.month_start,
  c.month_num,
  c.product_service_name,
  c.product_master_id,
  c.master_product_description,
  c.master_product_type,
  c.raw_product_type,
  c.product_type_actual_derived,
  c.product_type_short_derived,
  c.commission_product_service_derived,
  c.commission_category_final,
  c.quantity,
  c.price_ex_gst,
  c.price_incl_gst,
  c.price_gst_component,
  c.staff_commission_name,
  c.staff_work_name,
  c.existing_staff_paid_name,
  c.staff_paid_name_derived,
  c.staff_commission_id,
  c.staff_work_id,
  c.existing_staff_paid_id,
  c.derived_staff_paid_id,
  c.commission_display_name,
  c.commission_full_name,
  c.commission_primary_role,
  c.commission_remuneration_plan,
  c.work_display_name,
  c.work_full_name,
  c.work_primary_role,
  c.work_remuneration_plan,
  c.derived_staff_paid_display_name,
  c.derived_staff_paid_full_name,
  c.derived_staff_paid_primary_role,
  c.derived_staff_paid_remuneration_plan,
  c.derived_staff_paid_employment_type,
  c.derived_staff_paid_plan_id,
  c.derived_staff_paid_plan_name,
  c.commission_can_use_assistants,
  c.assistant_usage_alert_derived,
  c.staff_work_is_staff_paid_dax_parity,
  c.is_internal_non_commission,
  c.is_named_non_commission_category,
  c.actual_commission_rate,
  c.actual_commission_amt_ex_gst,
  c.theoretical_commission_rate,
  c.theoretical_commission_amt_ex_gst,
  c.assistant_commission_amt_ex_gst,
  c.calculation_alert,
  c.invoice_header,
  c.product_header,
  c.created_at,
  c.updated_at,
  CASE
    WHEN c.calculation_alert IS NULL THEN 'clean_commission_row'::text
    WHEN c.calculation_alert = ANY (ARRAY[
      'no_commission_greenfee'::text, 'no_commission_redo'::text,
      'no_commission_trainingproduct'::text,
      'no_commission_miscellaneousproduct'::text,
      'no_commission_voucher'::text, 'no_commission_unclassified'::text,
      'non_commission_internal'::text,
      'non_commission_unconfigured_paid_staff'::text
    ]) THEN 'expected_non_commission'::text
    WHEN c.calculation_alert = 'paid_staff_plan_not_matched'::text THEN 'configuration_issue'::text
    ELSE 'unexpected_issue'::text
  END AS qa_bucket,
  CASE
    WHEN c.calculation_alert IS NULL THEN 0
    WHEN c.calculation_alert = ANY (ARRAY[
      'no_commission_greenfee'::text, 'no_commission_redo'::text,
      'no_commission_trainingproduct'::text,
      'no_commission_miscellaneousproduct'::text,
      'no_commission_voucher'::text, 'no_commission_unclassified'::text,
      'non_commission_internal'::text,
      'non_commission_unconfigured_paid_staff'::text
    ]) THEN 1
    WHEN c.calculation_alert = 'paid_staff_plan_not_matched'::text THEN 2
    ELSE 3
  END AS qa_priority,
  -- NEW: passthrough of theoretical (potential) assistant commission.
  c.theoretical_assistant_commission_amt_ex_gst
FROM public.v_commission_calculations_core AS c;

ALTER VIEW public.v_commission_calculations_qa OWNER TO postgres;

COMMENT ON VIEW public.v_commission_calculations_qa IS
  'Commission calculations QA view. Adds qa_bucket / qa_priority on top of v_commission_calculations_core. Now also exposes theoretical_assistant_commission_amt_ex_gst as a passthrough column for downstream payroll / reporting views (My Sales Potential Assistant Comm.).';


-- ===========================================================================
-- 3. v_admin_payroll_lines (REPLACED)
--    Same explicit column list as before; payroll_status / is_payable /
--    requires_review synthetic columns preserved at their existing
--    positions. New theoretical_assistant_commission_amt_ex_gst column
--    appended at the END.
-- ===========================================================================
CREATE OR REPLACE VIEW public.v_admin_payroll_lines AS
SELECT
  q.id,
  q.import_batch_id,
  q.raw_row_id,
  q.location_id,
  q.invoice,
  q.sale_datetime,
  q.sale_date,
  q.day_name,
  q.month_start,
  q.month_num,
  q.customer_name,
  q.product_service_name,
  q.product_master_id,
  q.master_product_description,
  q.master_product_type,
  q.raw_product_type,
  q.product_type_actual_derived AS product_type_actual,
  q.product_type_short_derived  AS product_type_short,
  q.commission_product_service_derived AS commission_product_service,
  q.commission_category_final,
  q.quantity,
  q.price_ex_gst,
  q.price_incl_gst,
  q.price_gst_component,
  q.staff_commission_name,
  q.staff_work_name,
  q.existing_staff_paid_name,
  q.staff_paid_name_derived,
  q.staff_commission_id,
  q.staff_work_id,
  q.existing_staff_paid_id,
  q.derived_staff_paid_id,
  q.commission_display_name,
  q.commission_full_name,
  q.commission_primary_role,
  q.commission_remuneration_plan,
  q.work_display_name,
  q.work_full_name,
  q.work_primary_role,
  q.work_remuneration_plan,
  q.derived_staff_paid_display_name,
  q.derived_staff_paid_full_name,
  q.derived_staff_paid_primary_role,
  q.derived_staff_paid_remuneration_plan,
  q.derived_staff_paid_employment_type,
  q.derived_staff_paid_plan_id,
  q.derived_staff_paid_plan_name,
  q.commission_can_use_assistants,
  q.assistant_usage_alert_derived,
  q.staff_work_is_staff_paid_dax_parity,
  q.is_internal_non_commission,
  q.is_named_non_commission_category,
  q.actual_commission_rate,
  q.actual_commission_amt_ex_gst,
  q.theoretical_commission_rate,
  q.theoretical_commission_amt_ex_gst,
  q.assistant_commission_amt_ex_gst,
  q.calculation_alert,
  q.qa_bucket,
  q.qa_priority,
  CASE
    WHEN (q.qa_bucket = 'clean_commission_row'::text)
     AND (COALESCE(q.actual_commission_amt_ex_gst, 0::numeric) <> 0::numeric)
      THEN 'payable'::text
    WHEN (q.qa_bucket = 'clean_commission_row'::text)
     AND (COALESCE(q.actual_commission_amt_ex_gst, 0::numeric) = 0::numeric)
      THEN 'zero_value_commission_row'::text
    WHEN q.qa_bucket = 'expected_non_commission'::text THEN 'expected_no_commission'::text
    WHEN q.qa_bucket = 'configuration_issue'::text     THEN 'hold_config_issue'::text
    WHEN q.qa_bucket = 'unexpected_issue'::text        THEN 'hold_unexpected_issue'::text
    ELSE 'hold_unknown'::text
  END AS payroll_status,
  CASE
    WHEN (q.qa_bucket = 'clean_commission_row'::text)
     AND (COALESCE(q.actual_commission_amt_ex_gst, 0::numeric) <> 0::numeric) THEN true
    ELSE false
  END AS is_payable,
  CASE
    WHEN q.qa_bucket = ANY (ARRAY['configuration_issue'::text, 'unexpected_issue'::text]) THEN true
    ELSE false
  END AS requires_review,
  q.invoice_header,
  q.product_header,
  q.created_at,
  q.updated_at,
  -- NEW: passthrough of theoretical (potential) assistant commission.
  q.theoretical_assistant_commission_amt_ex_gst
FROM public.v_commission_calculations_qa AS q;

ALTER VIEW public.v_admin_payroll_lines OWNER TO postgres;

COMMENT ON VIEW public.v_admin_payroll_lines IS
  'Admin payroll line view. Adds payroll_status / is_payable / requires_review on top of v_commission_calculations_qa. Now also exposes theoretical_assistant_commission_amt_ex_gst as a passthrough column for downstream weekly aggregation (My Sales Potential Assistant Comm.).';


-- ===========================================================================
-- 4. v_admin_payroll_lines_weekly (REPLACED)
--    Previous form used SELECT l.*, <synthetic columns>. Adding the new
--    column to v_admin_payroll_lines makes l.* expand by one column,
--    which would shift the position of pay_week_start (the first
--    synthetic column) and break CREATE OR REPLACE.
--
--    To preserve every existing column position, this view now lists the
--    l.* columns explicitly in the same order as before, then the
--    existing synthetic columns at their existing positions, then
--    appends the new theoretical_assistant_commission_amt_ex_gst at the
--    end. Behaviour is identical to the previous SELECT l.* form for
--    all existing columns.
-- ===========================================================================
CREATE OR REPLACE VIEW public.v_admin_payroll_lines_weekly AS
SELECT
  l.id,
  l.import_batch_id,
  l.raw_row_id,
  l.location_id,
  l.invoice,
  l.sale_datetime,
  l.sale_date,
  l.day_name,
  l.month_start,
  l.month_num,
  l.customer_name,
  l.product_service_name,
  l.product_master_id,
  l.master_product_description,
  l.master_product_type,
  l.raw_product_type,
  l.product_type_actual,
  l.product_type_short,
  l.commission_product_service,
  l.commission_category_final,
  l.quantity,
  l.price_ex_gst,
  l.price_incl_gst,
  l.price_gst_component,
  l.staff_commission_name,
  l.staff_work_name,
  l.existing_staff_paid_name,
  l.staff_paid_name_derived,
  l.staff_commission_id,
  l.staff_work_id,
  l.existing_staff_paid_id,
  l.derived_staff_paid_id,
  l.commission_display_name,
  l.commission_full_name,
  l.commission_primary_role,
  l.commission_remuneration_plan,
  l.work_display_name,
  l.work_full_name,
  l.work_primary_role,
  l.work_remuneration_plan,
  l.derived_staff_paid_display_name,
  l.derived_staff_paid_full_name,
  l.derived_staff_paid_primary_role,
  l.derived_staff_paid_remuneration_plan,
  l.derived_staff_paid_employment_type,
  l.derived_staff_paid_plan_id,
  l.derived_staff_paid_plan_name,
  l.commission_can_use_assistants,
  l.assistant_usage_alert_derived,
  l.staff_work_is_staff_paid_dax_parity,
  l.is_internal_non_commission,
  l.is_named_non_commission_category,
  l.actual_commission_rate,
  l.actual_commission_amt_ex_gst,
  l.theoretical_commission_rate,
  l.theoretical_commission_amt_ex_gst,
  l.assistant_commission_amt_ex_gst,
  l.calculation_alert,
  l.qa_bucket,
  l.qa_priority,
  l.payroll_status,
  l.is_payable,
  l.requires_review,
  l.invoice_header,
  l.product_header,
  l.created_at,
  l.updated_at,
  (
    (l.sale_date
      - ((((EXTRACT(isodow FROM l.sale_date))::integer - 1))::double precision
        * '1 day'::interval))
  )::date AS pay_week_start,
  (
    (l.sale_date
      - ((((EXTRACT(isodow FROM l.sale_date))::integer - 1))::double precision
        * '1 day'::interval))
    + '6 days'::interval
  )::date AS pay_week_end,
  (
    (l.sale_date
      - ((((EXTRACT(isodow FROM l.sale_date))::integer - 1))::double precision
        * '1 day'::interval))
    + '10 days'::interval
  )::date AS pay_date,
  loc.name AS location_name,
  sm_paid.primary_location_id AS derived_staff_paid_primary_location_id,
  paid_loc.code               AS derived_staff_paid_primary_location_code,
  paid_loc.name               AS derived_staff_paid_primary_location_name,
  res_staff.final_staff_id    AS resolved_derived_staff_paid_id,
  COALESCE(sm_res.display_name,        l.derived_staff_paid_display_name)        AS resolved_derived_staff_paid_display_name,
  COALESCE(sm_res.full_name,           l.derived_staff_paid_full_name)           AS resolved_derived_staff_paid_full_name,
  COALESCE(sm_res.remuneration_plan,   l.derived_staff_paid_remuneration_plan)   AS resolved_derived_staff_paid_remuneration_plan,
  sm_res.primary_location_id           AS resolved_derived_staff_paid_primary_location_id,
  paid_loc_res.code                    AS resolved_derived_staff_paid_primary_location_code,
  paid_loc_res.name                    AS resolved_derived_staff_paid_primary_location_name,
  -- NEW (appended at end): passthrough of theoretical (potential)
  -- assistant commission. Same line-level basis as
  -- assistant_commission_amt_ex_gst; weekly aggregation lives in
  -- v_admin_payroll_summary_weekly's siblings (e.g. the My Sales RPC).
  l.theoretical_assistant_commission_amt_ex_gst
FROM public.v_admin_payroll_lines AS l
LEFT JOIN public.locations AS loc ON loc.id = l.location_id
LEFT JOIN public.staff_members AS sm_paid ON sm_paid.id = l.derived_staff_paid_id
LEFT JOIN public.locations AS paid_loc ON paid_loc.id = sm_paid.primary_location_id
LEFT JOIN LATERAL (
  SELECT
    NULLIF(
      trim(lower(coalesce(l.derived_staff_paid_display_name, l.staff_paid_name_derived, ''))),
      ''
    ) AS cand_dn,
    NULLIF(trim(lower(coalesce(l.derived_staff_paid_full_name, ''))), '') AS cand_fn
) AS nm ON true
LEFT JOIN LATERAL (
  SELECT
    CASE
      WHEN l.derived_staff_paid_id IS NOT NULL THEN l.derived_staff_paid_id
      WHEN nm.cand_dn IS NOT NULL
        AND (
          SELECT count(*)::integer
          FROM public.staff_members sm
          WHERE lower(trim(sm.display_name)) = nm.cand_dn
        ) = 1
        THEN (
          SELECT sm.id
          FROM public.staff_members sm
          WHERE lower(trim(sm.display_name)) = nm.cand_dn
          LIMIT 1
        )
      WHEN nm.cand_dn IS NOT NULL
        AND (
          SELECT count(*)::integer
          FROM public.staff_members sm
          WHERE lower(trim(sm.full_name)) = nm.cand_dn
        ) = 1
        THEN (
          SELECT sm.id
          FROM public.staff_members sm
          WHERE lower(trim(sm.full_name)) = nm.cand_dn
          LIMIT 1
        )
      WHEN nm.cand_fn IS NOT NULL
        AND nm.cand_fn IS DISTINCT FROM nm.cand_dn
        AND (
          SELECT count(*)::integer
          FROM public.staff_members sm
          WHERE lower(trim(sm.full_name)) = nm.cand_fn
        ) = 1
        THEN (
          SELECT sm.id
          FROM public.staff_members sm
          WHERE lower(trim(sm.full_name)) = nm.cand_fn
          LIMIT 1
        )
      WHEN nm.cand_fn IS NOT NULL
        AND nm.cand_fn IS DISTINCT FROM nm.cand_dn
        AND (
          SELECT count(*)::integer
          FROM public.staff_members sm
          WHERE lower(trim(sm.display_name)) = nm.cand_fn
        ) = 1
        THEN (
          SELECT sm.id
          FROM public.staff_members sm
          WHERE lower(trim(sm.display_name)) = nm.cand_fn
          LIMIT 1
        )
      ELSE NULL
    END AS final_staff_id
) AS res_staff ON true
LEFT JOIN public.staff_members AS sm_res ON sm_res.id = res_staff.final_staff_id
LEFT JOIN public.locations AS paid_loc_res ON paid_loc_res.id = sm_res.primary_location_id;

ALTER VIEW public.v_admin_payroll_lines_weekly OWNER TO postgres;

COMMENT ON VIEW public.v_admin_payroll_lines_weekly IS
  'Admin payroll lines with pay week, sale location, derived paid-staff primary location, resolved paid-staff identity (unique staff_members match on display/full name when derived_staff_paid_id is null), and theoretical_assistant_commission_amt_ex_gst passthrough for the My Sales Potential Assistant Comm. column. All previously existing columns are preserved in their previous positions; only the new theoretical assistant column is appended at the end.';


-- ===========================================================================
-- 5. public.get_my_sales_trend_weekly (DROP + CREATE)
--    DROP + CREATE because the RETURNS TABLE signature gains a new
--    column (total_theoretical_assistant_commission_ex_gst) and
--    CREATE OR REPLACE FUNCTION cannot change the output column list.
--
--    Behaviour for all existing columns is unchanged. The new column is
--    a simple sum of the trusted upstream
--    theoretical_assistant_commission_amt_ex_gst (no new calculation
--    path; mirrors the existing total_assistant_commission_ex_gst
--    aggregation pattern).
-- ===========================================================================
DROP FUNCTION IF EXISTS public.get_my_sales_trend_weekly();

CREATE OR REPLACE FUNCTION public.get_my_sales_trend_weekly()
RETURNS TABLE (
  staff_member_id                              uuid,
  staff_display_name                           text,
  staff_full_name                              text,
  pay_week_start                               date,
  pay_week_end                                 date,
  pay_date                                     date,
  effective_primary_role                       text,
  effective_remuneration_plan                  text,
  total_sales_ex_gst                           numeric,
  total_actual_commission_ex_gst               numeric,
  total_theoretical_commission_ex_gst          numeric,
  total_assistant_commission_ex_gst            numeric,
  total_theoretical_assistant_commission_ex_gst numeric,
  assistant_commission_contributors            jsonb
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
  WITH me AS (
    SELECT a.staff_member_id
    FROM public.staff_member_user_access a
    WHERE a.user_id = auth.uid()
      AND COALESCE(a.is_active, false) = true
      AND a.staff_member_id IS NOT NULL
    LIMIT 1
  ),
  weekly AS (
    -- One row per (staff, pay_week) combined across locations. Same
    -- voucher exclusion as v_admin_payroll_summary_weekly.total_sales_ex_gst.
    SELECT
      l.derived_staff_paid_id                AS staff_member_id,
      l.pay_week_start,
      MAX(l.pay_week_end)                    AS pay_week_end,
      MAX(l.pay_date)                        AS pay_date,
      MAX(l.derived_staff_paid_display_name) AS staff_display_name,
      MAX(l.derived_staff_paid_full_name)    AS staff_full_name,
      ROUND(SUM(
        CASE
          WHEN public.is_voucher_sale_row(
            l.raw_product_type, l.product_type_actual,
            l.product_type_short, l.commission_product_service
          ) THEN 0::numeric
          ELSE COALESCE(l.price_ex_gst, 0::numeric)
        END
      ), 2) AS total_sales_ex_gst,
      ROUND(SUM(COALESCE(l.actual_commission_amt_ex_gst,      0::numeric)), 2) AS total_actual_commission_ex_gst,
      ROUND(SUM(COALESCE(l.theoretical_commission_amt_ex_gst, 0::numeric)), 2) AS total_theoretical_commission_ex_gst,
      ROUND(SUM(COALESCE(l.assistant_commission_amt_ex_gst,   0::numeric)), 2) AS total_assistant_commission_ex_gst,
      -- NEW: potential assistant commission, summed from the trusted
      -- upstream line-level field added in this migration.
      ROUND(SUM(COALESCE(l.theoretical_assistant_commission_amt_ex_gst, 0::numeric)), 2)
        AS total_theoretical_assistant_commission_ex_gst
    FROM public.v_admin_payroll_lines_weekly l
    JOIN me ON me.staff_member_id = l.derived_staff_paid_id
    GROUP BY l.derived_staff_paid_id, l.pay_week_start
  ),
  contrib AS (
    -- Assistant breakdown sourced from the same payroll line rows that
    -- contribute to total_assistant_commission_ex_gst. Actual only;
    -- there is intentionally no contributor breakdown for the new
    -- theoretical column because the My Sales spec only shows
    -- contributor icons for actual assistant commission.
    SELECT
      l.derived_staff_paid_id AS staff_member_id,
      l.pay_week_start,
      l.staff_work_id         AS assistant_staff_member_id,
      COALESCE(
        NULLIF(TRIM(l.work_display_name), ''),
        NULLIF(TRIM(l.work_full_name),    ''),
        '(Unknown assistant)'
      ) AS assistant_display_name,
      ROUND(SUM(COALESCE(l.assistant_commission_amt_ex_gst, 0::numeric)), 2)
        AS amount_ex_gst
    FROM public.v_admin_payroll_lines_weekly l
    JOIN me ON me.staff_member_id = l.derived_staff_paid_id
    WHERE COALESCE(l.assistant_commission_amt_ex_gst, 0::numeric) > 0::numeric
    GROUP BY
      l.derived_staff_paid_id,
      l.pay_week_start,
      l.staff_work_id,
      COALESCE(
        NULLIF(TRIM(l.work_display_name), ''),
        NULLIF(TRIM(l.work_full_name),    ''),
        '(Unknown assistant)'
      )
  ),
  contrib_agg AS (
    SELECT
      c.staff_member_id,
      c.pay_week_start,
      jsonb_agg(
        jsonb_build_object(
          'staff_member_id', c.assistant_staff_member_id,
          'display_name',    c.assistant_display_name,
          'amount_ex_gst',   c.amount_ex_gst
        )
        ORDER BY lower(c.assistant_display_name), c.assistant_staff_member_id
      ) AS assistant_commission_contributors
    FROM contrib c
    GROUP BY c.staff_member_id, c.pay_week_start
  )
  SELECT
    w.staff_member_id,
    w.staff_display_name,
    w.staff_full_name,
    w.pay_week_start,
    w.pay_week_end,
    w.pay_date,
    COALESCE(eff.primary_role,      sm.primary_role)      AS effective_primary_role,
    COALESCE(eff.remuneration_plan, sm.remuneration_plan) AS effective_remuneration_plan,
    w.total_sales_ex_gst,
    w.total_actual_commission_ex_gst,
    w.total_theoretical_commission_ex_gst,
    w.total_assistant_commission_ex_gst,
    w.total_theoretical_assistant_commission_ex_gst,
    COALESCE(ca.assistant_commission_contributors, '[]'::jsonb) AS assistant_commission_contributors
  FROM weekly w
  LEFT JOIN public.staff_members sm ON sm.id = w.staff_member_id
  LEFT JOIN LATERAL public.staff_profile_at(w.staff_member_id, w.pay_week_start) eff ON true
  LEFT JOIN contrib_agg ca
    ON ca.staff_member_id = w.staff_member_id
   AND ca.pay_week_start  = w.pay_week_start
  ORDER BY w.pay_week_start DESC;
$fn$;

ALTER FUNCTION public.get_my_sales_trend_weekly() OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.get_my_sales_trend_weekly() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_sales_trend_weekly() TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_my_sales_trend_weekly() TO service_role;

COMMENT ON FUNCTION public.get_my_sales_trend_weekly() IS
  'My Sales (/app/my-sales) personal Staff Trends data: one row per pay week for the calling user''s mapped staff_member_id, combined across locations. Totals come from v_admin_payroll_lines_weekly (same source as Sales Summary / Staff Trends; voucher rows excluded from total_sales_ex_gst via public.is_voucher_sale_row). effective_primary_role / effective_remuneration_plan resolved at pay_week_start via public.staff_profile_at with COALESCE fallback to current staff_members. assistant_commission_contributors aggregates the assistant breakdown straight from the same payroll line rows that feed total_assistant_commission_ex_gst (no new calculation path). total_theoretical_assistant_commission_ex_gst is a SUM of the line-level theoretical_assistant_commission_amt_ex_gst added in the 20260828123000 migration (price_ex_gst * theoretical_commission_rate for Assistant work under the benchmark Commission plan) and is useful for wage stylists where actual_commission_rate, and therefore actual assistant commission, is null. Returns zero rows for callers without an active staff_members mapping.';


-- ===========================================================================
-- 6. Validation (informational NOTICEs only; never fails the migration).
--    A. Confirm the new line-level column exists on v_commission_calculations_core.
--    B. Confirm it propagated through to v_admin_payroll_lines_weekly.
--    C. Sample wage-stylist coverage (any wage stylist with non-zero
--       theoretical assistant commission in the last 90 days).
--    D. Sample commission-stylist redundancy (commission stylists should
--       have theoretical assistant commission == actual assistant commission
--       at the weekly level, modulo rounding).
-- ===========================================================================
DO $$
DECLARE
  v_core_col_exists  boolean;
  v_weekly_col_exists boolean;
  v_wage_coverage    integer;
  v_wage_total       numeric;
  v_commission_drift integer;
BEGIN
  -- A.
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'v_commission_calculations_core'
      AND column_name  = 'theoretical_assistant_commission_amt_ex_gst'
  )
  INTO v_core_col_exists;
  RAISE NOTICE
    '[20260828123000] v_commission_calculations_core.theoretical_assistant_commission_amt_ex_gst exists: %',
    v_core_col_exists;

  -- B.
  SELECT EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name   = 'v_admin_payroll_lines_weekly'
      AND column_name  = 'theoretical_assistant_commission_amt_ex_gst'
  )
  INTO v_weekly_col_exists;
  RAISE NOTICE
    '[20260828123000] v_admin_payroll_lines_weekly.theoretical_assistant_commission_amt_ex_gst exists: %',
    v_weekly_col_exists;

  -- C. Wage stylist coverage in the last 90 days. Count of (staff,
  --    pay_week) pairs that have non-zero theoretical assistant
  --    commission AND a Wage plan AND a stylist-like primary_role
  --    (matches Leah's expected profile).
  SELECT
    count(*)::integer,
    ROUND(COALESCE(SUM(weekly_amt), 0::numeric), 2)
  INTO v_wage_coverage, v_wage_total
  FROM (
    SELECT
      l.derived_staff_paid_id,
      l.pay_week_start,
      ROUND(SUM(COALESCE(l.theoretical_assistant_commission_amt_ex_gst, 0::numeric)), 2) AS weekly_amt
    FROM public.v_admin_payroll_lines_weekly l
    LEFT JOIN public.staff_members sm ON sm.id = l.derived_staff_paid_id
    WHERE l.sale_date >= (current_date - INTERVAL '90 days')
      AND lower(COALESCE(sm.remuneration_plan, '')) = 'wage'
      AND lower(COALESCE(sm.primary_role,     '')) LIKE '%stylist%'
    GROUP BY l.derived_staff_paid_id, l.pay_week_start
    HAVING ROUND(SUM(COALESCE(l.theoretical_assistant_commission_amt_ex_gst, 0::numeric)), 2) > 0
  ) s;
  RAISE NOTICE
    '[20260828123000] wage-stylist weeks with non-zero theoretical assistant commission (last 90 days): % rows, $% total',
    v_wage_coverage, v_wage_total;

  -- D. Commission stylist drift check. Count of (staff, pay_week) pairs
  --    where the staff is on a Commission plan and the new theoretical
  --    assistant total drifts > $0.05 from the existing actual assistant
  --    total. Expected to be 0 for clean Commission stylists in the
  --    happy path; non-zero rows are informational (could come from
  --    rate/category overrides, but the spec says theoretical should
  --    equal actual when the stylist IS on the benchmark plan).
  SELECT count(*)::integer
  INTO v_commission_drift
  FROM (
    SELECT
      l.derived_staff_paid_id,
      l.pay_week_start,
      ROUND(SUM(COALESCE(l.assistant_commission_amt_ex_gst,             0::numeric)), 2) AS actual_amt,
      ROUND(SUM(COALESCE(l.theoretical_assistant_commission_amt_ex_gst, 0::numeric)), 2) AS theoretical_amt
    FROM public.v_admin_payroll_lines_weekly l
    LEFT JOIN public.staff_members sm ON sm.id = l.derived_staff_paid_id
    WHERE l.sale_date >= (current_date - INTERVAL '90 days')
      AND lower(COALESCE(sm.remuneration_plan, '')) = 'commission'
    GROUP BY l.derived_staff_paid_id, l.pay_week_start
    HAVING abs(
      ROUND(SUM(COALESCE(l.assistant_commission_amt_ex_gst,             0::numeric)), 2)
      - ROUND(SUM(COALESCE(l.theoretical_assistant_commission_amt_ex_gst, 0::numeric)), 2)
    ) > 0.05::numeric
  ) s;
  RAISE NOTICE
    '[20260828123000] commission-stylist weeks where theoretical assistant total drifts > $0.05 from actual (last 90 days): % rows (expected: 0 or close to 0)',
    v_commission_drift;
END
$$ LANGUAGE plpgsql;
