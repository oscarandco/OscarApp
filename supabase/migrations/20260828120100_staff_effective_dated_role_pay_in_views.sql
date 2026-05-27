-- Phase 2 of the staff effective-dated role/pay history rollout.
-- Reroutes the three commission-pipeline views and the FTE-consuming KPI
-- RPCs to read staff role/secondary_roles/employment_type/remuneration_plan/
-- fte/primary_location_id from public.staff_role_assignments effective at
-- the row's sale_date (or, for KPI period rollups, at v_mtd_through).
--
-- Phase 1 backfilled exactly one open-ended assignment per staff_members row
-- with the current values. As long as no historical corrections have been
-- entered yet, every effective lookup returns the same value as the current
-- staff_members row → no numbers should move when this migration deploys.
--
-- Fallback rule (defensive): if staff_profile_at(...) returns no row for a
-- given (staff_id, date), we COALESCE back to the current staff_members
-- value. This preserves today's behaviour for any rare staff/sale_date pair
-- that doesn't have a covering history row (e.g. sales pre-dating the
-- backfilled sentinel start, or staff rows added between Phase 1 and
-- Phase 4 without a backfill top-up).
--
-- Affected objects:
--   1. public.v_sales_transactions_powerbi_parity        (REPLACED)
--   2. public.v_commission_calculations_core             (REPLACED)
--   3. public.v_sales_transactions_enriched              (REPLACED)
--   4. public.get_staff_fte_for_kpi_display              (DROP + RECREATE w/ optional p_period_end_date)
--   5. public.get_kpi_stylist_profitability_live         (REPLACED)
--   6. public.get_kpi_stylist_comparisons_live           (REPLACED)
--   7. public.get_kpi_stylist_comparison_leaders_live    (REPLACED)
--
-- Unchanged in this phase (deliberate):
--   * v_commission_calculations_qa, v_admin_payroll_lines, v_admin_payroll_lines_weekly,
--     v_admin_payroll_summary_weekly — they inherit the fix transparently because
--     they passthrough the parity/core columns.
--   * Voucher exclusion logic, KPI revenue / avg spend / assistant utilisation /
--     guests / new_clients / drilldown / snapshot RPCs.
--   * Contractor invoice RPCs (preview / batch / create / void / list).
--     Saved invoices are snapshots; preview/batch read v_admin_payroll_lines_weekly
--     and pick up the fix transparently.
--   * Staff Admin UI (Phase 4).
--   * Frontend types (no signature changes).
--
-- Spec source: investigation/design report (Bernie–Lorine recalculation bug).

-- ===========================================================================
-- 1. public.v_sales_transactions_powerbi_parity (REPLACED)
--    Adds two LATERAL joins to public.staff_profile_at:
--      sc_eff for the commission staff (matched by id, or by sc.id when only
--              the name was matched in the existing sc lateral)
--      sw_eff for the work staff (same pattern)
--    Then COALESCEs the effective role/plan/employment columns over the
--    current staff_members lookup. The rp join also keys off the effective
--    plan so commission_can_use_assistants is effective-dated.
-- ===========================================================================
CREATE OR REPLACE VIEW public.v_sales_transactions_powerbi_parity AS
WITH base AS (
  SELECT
    st.id,
    st.import_batch_id,
    st.raw_row_id,
    st.location_id,
    st.invoice,
    st.customer_name,
    st.sale_datetime,
    st.sale_date,
    st.day_name,
    st.month_start,
    st.month_num,
    st.product_service_name,
    st.product_master_id,
    st.raw_product_type,
    st.product_type_actual AS existing_product_type_actual,
    st.product_type_short  AS existing_product_type_short,
    st.commission_product_service AS existing_commission_product_service,
    st.quantity,
    st.price_ex_gst,
    st.price_incl_gst,
    st.price_gst_component,
    st.staff_commission_name,
    st.staff_work_name,
    st.staff_paid_name AS existing_staff_paid_name,
    st.staff_commission_id,
    st.staff_work_id,
    st.staff_paid_id,
    st.staff_commission_type,
    st.staff_work_type,
    st.staff_paid_type,
    st.assistant_usage_alert AS existing_assistant_usage_alert,
    st.staff_work_is_staff_paid,
    st.invoice_header,
    st.product_header,
    st.created_at,
    st.updated_at,
    pm.product_description AS master_product_description,
    pm.product_type        AS master_product_type,
    COALESCE(sc.display_name, NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), '')) AS commission_display_name,
    COALESCE(sc.full_name,    NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), '')) AS commission_full_name,
    -- Effective-dated role/plan/employment for the commission staff:
    COALESCE(sc_eff.primary_role,      sc.primary_role)      AS commission_primary_role,
    COALESCE(sc_eff.remuneration_plan, sc.remuneration_plan) AS commission_remuneration_plan,
    COALESCE(sc_eff.employment_type,   sc.employment_type)   AS commission_employment_type,
    COALESCE(sw.display_name, NULLIF(TRIM(COALESCE(st.staff_work_name, '')), ''), NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), '')) AS work_display_name,
    COALESCE(sw.full_name,    NULLIF(TRIM(COALESCE(st.staff_work_name, '')), ''), NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), '')) AS work_full_name,
    -- Effective-dated role/plan/employment for the work staff:
    COALESCE(sw_eff.primary_role,      sw.primary_role)      AS work_primary_role,
    COALESCE(sw_eff.remuneration_plan, sw.remuneration_plan) AS work_remuneration_plan,
    COALESCE(sw_eff.employment_type,   sw.employment_type)   AS work_employment_type,
    rp.plan_name           AS commission_plan_name,
    rp.can_use_assistants  AS commission_can_use_assistants
  FROM public.sales_transactions st
    LEFT JOIN public.product_master pm
      ON lower(TRIM(st.product_service_name)) = lower(TRIM(pm.product_description))
    -- Current commission-staff row (unchanged from previous version).
    LEFT JOIN LATERAL (
      SELECT sm.*
      FROM public.staff_members sm
      WHERE (st.staff_commission_id IS NOT NULL AND sm.id = st.staff_commission_id)
         OR (st.staff_commission_id IS NULL
             AND NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), '') IS NOT NULL
             AND lower(TRIM(st.staff_commission_name)) = lower(TRIM(sm.display_name))
             AND sm.is_active = true)
      ORDER BY
        CASE
          WHEN st.staff_commission_id IS NOT NULL AND sm.id = st.staff_commission_id THEN 0
          ELSE 1
        END
      LIMIT 1
    ) sc ON true
    -- Current work-staff row (unchanged from previous version).
    LEFT JOIN LATERAL (
      SELECT sm.*
      FROM public.staff_members sm
      WHERE (st.staff_work_id IS NOT NULL AND sm.id = st.staff_work_id)
         OR (st.staff_work_id IS NULL
             AND NULLIF(TRIM(COALESCE(st.staff_work_name, '')), '') IS NOT NULL
             AND lower(TRIM(st.staff_work_name)) = lower(TRIM(sm.display_name))
             AND sm.is_active = true)
      ORDER BY
        CASE
          WHEN st.staff_work_id IS NOT NULL AND sm.id = st.staff_work_id THEN 0
          ELSE 1
        END
      LIMIT 1
    ) sw ON true
    -- Effective-dated overlays. We pass COALESCE(direct id, lateral-matched id)
    -- so that name-only matched rows still get the effective lookup.
    LEFT JOIN LATERAL public.staff_profile_at(
      COALESCE(st.staff_commission_id, sc.id),
      st.sale_date
    ) sc_eff ON true
    LEFT JOIN LATERAL public.staff_profile_at(
      COALESCE(st.staff_work_id, sw.id),
      st.sale_date
    ) sw_eff ON true
    -- Plan lookup now keys off the effective commission plan.
    LEFT JOIN public.remuneration_plans rp
      ON lower(TRIM(COALESCE(sc_eff.remuneration_plan, sc.remuneration_plan)))
         = lower(TRIM(rp.plan_name))
),
derived AS (
  SELECT
    b.id,
    b.import_batch_id,
    b.raw_row_id,
    b.location_id,
    b.invoice,
    b.customer_name,
    b.sale_datetime,
    b.sale_date,
    b.day_name,
    b.month_start,
    b.month_num,
    b.product_service_name,
    b.product_master_id,
    b.raw_product_type,
    b.existing_product_type_actual,
    b.existing_product_type_short,
    b.existing_commission_product_service,
    b.quantity,
    b.price_ex_gst,
    b.price_incl_gst,
    b.price_gst_component,
    b.staff_commission_name,
    b.staff_work_name,
    b.existing_staff_paid_name,
    b.staff_commission_id,
    b.staff_work_id,
    b.staff_paid_id,
    b.staff_commission_type,
    b.staff_work_type,
    b.staff_paid_type,
    b.existing_assistant_usage_alert,
    b.staff_work_is_staff_paid,
    b.invoice_header,
    b.product_header,
    b.created_at,
    b.updated_at,
    b.master_product_description,
    b.master_product_type,
    b.commission_display_name,
    b.commission_full_name,
    b.commission_primary_role,
    b.commission_remuneration_plan,
    b.commission_employment_type,
    b.work_display_name,
    b.work_full_name,
    b.work_primary_role,
    b.work_remuneration_plan,
    b.work_employment_type,
    b.commission_plan_name,
    b.commission_can_use_assistants,
    CASE
      WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
      WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
      WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
        CASE
          WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
          WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
          ELSE b.raw_product_type
        END
      ELSE b.master_product_type
    END AS product_type_actual_derived,
    CASE
      WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Prof. Prod.'::text
      WHEN (
        CASE
          WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
          WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
          WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
            CASE
              WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
              WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
              ELSE b.raw_product_type
            END
          ELSE b.master_product_type
        END = 'Retail Product'
      ) THEN 'Retail Prod.'::text
      WHEN (
        CASE
          WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
          WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
          WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
            CASE
              WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
              WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
              ELSE b.raw_product_type
            END
          ELSE b.master_product_type
        END = 'Professional Product'
      ) THEN 'Prof. Prod.'::text
      WHEN (
        CASE
          WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
          WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
          WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
            CASE
              WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
              WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
              ELSE b.raw_product_type
            END
          ELSE b.master_product_type
        END = 'Service'
      ) THEN 'Services'::text
      ELSE
        CASE
          WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
          ELSE
            CASE
              WHEN (b.master_product_type IS NOT NULL) AND (TRIM(COALESCE(b.master_product_type, '')) <> '') THEN b.master_product_type
              ELSE b.raw_product_type
            END
        END
    END AS product_type_short_derived,
    CASE
      WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Comm - Products'::text
      WHEN (
        CASE
          WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
          WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
          WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
            CASE
              WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
              WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
              ELSE b.raw_product_type
            END
          ELSE b.master_product_type
        END = 'Retail Product'
      ) THEN 'Comm - Products'::text
      WHEN (
        CASE
          WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
          WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
          WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
            CASE
              WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
              WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
              ELSE b.raw_product_type
            END
          ELSE b.master_product_type
        END = 'Professional Product'
      ) THEN 'Comm - Products'::text
      WHEN (
        CASE
          WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
          WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
          WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
            CASE
              WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
              WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
              ELSE b.raw_product_type
            END
          ELSE b.master_product_type
        END = 'Service'
      ) THEN 'Comm - Services'::text
      ELSE '-'::text
    END AS commission_product_service_derived,
    CASE
      WHEN upper(TRIM(COALESCE(b.work_primary_role, ''))) = 'INTERNAL' THEN NULL::text
      WHEN upper(TRIM(COALESCE(b.work_primary_role, ''))) = 'ASSISTANT' AND COALESCE(b.commission_can_use_assistants, false) = false THEN NULL::text
      WHEN upper(TRIM(COALESCE(b.work_primary_role, ''))) = 'ASSISTANT' AND COALESCE(b.commission_can_use_assistants, false) = true  THEN b.staff_commission_name
      WHEN (lower(TRIM(COALESCE(b.work_remuneration_plan, ''))) = 'wage')
           AND (COALESCE(b.raw_product_type, '') <> ALL (ARRAY['Voucher'::text, 'Unclassified'::text]))
           AND (NOT lower(TRIM(COALESCE(b.product_service_name, ''))) = ANY (ARRAY['green fee'::text, 'redo'::text, 'training product'::text, 'miscellaneous'::text]))
           AND (NOT upper(COALESCE(b.product_header, '')) LIKE '%TONER WITH OTHER SERVICE%')
           AND (NOT upper(COALESCE(b.product_header, '')) LIKE '%BONDED EXTENSIONS%')
           AND (NOT upper(COALESCE(b.product_header, '')) LIKE '%EXTENSIONS BONDS%')
           AND (NOT upper(COALESCE(b.product_header, '')) LIKE '%EXTENSIONS (TAPES%')
           AND (
             CASE
               WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
               WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
               WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
                 CASE
                   WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
                   WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
                   ELSE b.raw_product_type
                 END
               ELSE b.master_product_type
             END = 'Retail Product'
           )
        THEN b.staff_work_name
      WHEN (
        upper(TRIM(COALESCE(b.work_primary_role, ''))) <> 'INTERNAL'
        AND (
          lower(TRIM(COALESCE(b.staff_work_is_staff_paid, ''))) = 'yes'
          OR (
            NULLIF(TRIM(COALESCE(b.staff_work_name, '')), '') IS NOT NULL
            AND lower(TRIM(COALESCE(b.staff_commission_name, '')))
                = lower(TRIM(COALESCE(b.staff_work_name, '')))
          )
        )
      )
        THEN COALESCE(
          NULLIF(TRIM(COALESCE(b.work_display_name, '')), ''),
          NULLIF(TRIM(COALESCE(b.staff_work_name, '')), '')
        )
      WHEN lower(TRIM(COALESCE(b.work_remuneration_plan, ''))) = 'wage' THEN NULL::text
      ELSE b.staff_work_name
    END AS staff_paid_name_derived,
    CASE
      WHEN upper(TRIM(COALESCE(b.work_primary_role, ''))) = 'ASSISTANT' AND b.commission_can_use_assistants = false THEN 'Ineligible assistant usage'::text
      ELSE NULL::text
    END AS assistant_usage_alert_derived,
    CASE
      WHEN b.staff_commission_name = b.staff_work_name THEN 'Yes'::text
      ELSE 'No'::text
    END AS staff_work_is_staff_paid_dax_parity,
    CASE
      WHEN lower(TRIM(COALESCE(b.product_service_name, ''))) = 'green fee'         THEN 'no_commission_greenfee'::text
      WHEN lower(TRIM(COALESCE(b.product_service_name, ''))) = 'redo'              THEN 'no_commission_redo'::text
      WHEN lower(TRIM(COALESCE(b.product_service_name, ''))) = 'training product'  THEN 'no_commission_trainingproduct'::text
      WHEN lower(TRIM(COALESCE(b.product_service_name, ''))) = 'miscellaneous'     THEN 'no_commission_miscellaneousproduct'::text
      WHEN COALESCE(b.raw_product_type, '') = 'Voucher'                            THEN 'no_commission_voucher'::text
      WHEN COALESCE(b.raw_product_type, '') = 'Unclassified'                       THEN 'no_commission_unclassified'::text
      WHEN upper(COALESCE(b.product_header, '')) LIKE '%TONER WITH OTHER SERVICE%' THEN 'toner_with_other_service'::text
      WHEN upper(COALESCE(b.product_header, '')) LIKE '%BONDED EXTENSIONS%'        THEN 'extensions_product'::text
      WHEN upper(COALESCE(b.product_header, '')) LIKE '%EXTENSIONS BONDS%'         THEN 'extensions_product'::text
      WHEN upper(COALESCE(b.product_header, '')) LIKE '%EXTENSIONS (TAPES%'        THEN 'extensions_service'::text
      WHEN (
        CASE
          WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
          WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
          WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
            CASE
              WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
              WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
              ELSE b.raw_product_type
            END
          ELSE b.master_product_type
        END = 'Retail Product'
      ) THEN 'retail_product'::text
      WHEN (
        CASE
          WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
          WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
          WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
            CASE
              WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
              WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
              ELSE b.raw_product_type
            END
          ELSE b.master_product_type
        END = 'Professional Product'
      ) THEN 'professional_product'::text
      WHEN (
        CASE
          WHEN right(COALESCE(b.product_service_name, ''), 1) = '*' THEN 'Professional Product'::text
          WHEN COALESCE(b.raw_product_type, '') = ANY (ARRAY['Unclassified'::text, 'Voucher'::text]) THEN '-'::text
          WHEN (b.master_product_type IS NULL) OR (TRIM(COALESCE(b.master_product_type, '')) = '') THEN
            CASE
              WHEN COALESCE(b.raw_product_type, '') = 'Service' THEN 'Service'::text
              WHEN COALESCE(b.raw_product_type, '') = 'Retail'  THEN 'Retail Product'::text
              ELSE b.raw_product_type
            END
          ELSE b.master_product_type
        END = 'Service'
      ) THEN 'service'::text
      ELSE NULL::text
    END AS commission_category_final
  FROM base b
)
SELECT
  id, import_batch_id, raw_row_id, location_id, invoice, customer_name,
  sale_datetime, sale_date, day_name, month_start, month_num,
  product_service_name, product_master_id, raw_product_type,
  existing_product_type_actual, existing_product_type_short,
  existing_commission_product_service, quantity, price_ex_gst,
  price_incl_gst, price_gst_component, staff_commission_name,
  staff_work_name, existing_staff_paid_name, staff_commission_id,
  staff_work_id, staff_paid_id, staff_commission_type, staff_work_type,
  staff_paid_type, existing_assistant_usage_alert, staff_work_is_staff_paid,
  invoice_header, product_header, created_at, updated_at,
  master_product_description, master_product_type,
  commission_display_name, commission_full_name, commission_primary_role,
  commission_remuneration_plan, commission_employment_type,
  work_display_name, work_full_name, work_primary_role,
  work_remuneration_plan, work_employment_type, commission_plan_name,
  commission_can_use_assistants, product_type_actual_derived,
  product_type_short_derived, commission_product_service_derived,
  staff_paid_name_derived, assistant_usage_alert_derived,
  staff_work_is_staff_paid_dax_parity, commission_category_final
FROM derived d;

ALTER VIEW public.v_sales_transactions_powerbi_parity OWNER TO postgres;

COMMENT ON VIEW public.v_sales_transactions_powerbi_parity IS
  'PowerBI parity view for sales_transactions. As of Phase 2 the commission_primary_role / commission_remuneration_plan / commission_employment_type / work_primary_role / work_remuneration_plan / work_employment_type / commission_can_use_assistants columns are derived from public.staff_role_assignments effective at sale_date, with COALESCE fallback to current staff_members values for any (staff_id, sale_date) pair not covered by history.';


-- ===========================================================================
-- 2. public.v_commission_calculations_core (REPLACED)
--    paid_staff_resolved CTE adds a LATERAL to staff_profile_at(sm_paid.id,
--    p.sale_date) so derived_staff_paid_primary_role / _remuneration_plan /
--    _employment_type and the rp_paid plan lookup are all effective-dated.
--    The rest of the view (rated CTE + final SELECT) is unchanged.
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
    -- Effective-dated paid-staff role/plan/employment.
    COALESCE(sm_paid_eff.primary_role,      sm_paid.primary_role)      AS derived_staff_paid_primary_role,
    COALESCE(sm_paid_eff.remuneration_plan, sm_paid.remuneration_plan) AS derived_staff_paid_remuneration_plan,
    COALESCE(sm_paid_eff.employment_type,   sm_paid.employment_type)   AS derived_staff_paid_employment_type,
    rp_paid.id        AS derived_staff_paid_plan_id,
    rp_paid.plan_name AS derived_staff_paid_plan_name,
    rp_commission.id        AS benchmark_commission_plan_id,
    rp_commission.plan_name AS benchmark_commission_plan_name
  FROM parity p
    LEFT JOIN public.staff_members sm_paid ON (
      (p.staff_paid_name_derived IS NOT NULL
       AND lower(TRIM(p.staff_paid_name_derived)) = lower(TRIM(sm_paid.display_name)))
      OR (p.staff_paid_name_derived IS NULL
          AND p.staff_work_id IS NOT NULL
          AND p.staff_work_is_staff_paid_dax_parity = 'Yes'
          AND sm_paid.id = p.staff_work_id)
    )
    -- Effective-dated overlay for the resolved paid staff.
    LEFT JOIN LATERAL public.staff_profile_at(sm_paid.id, p.sale_date) sm_paid_eff
      ON true
    -- rp_paid now keys off the effective remuneration plan so the rate
    -- lookup downstream uses the historically-correct plan.
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
  updated_at
FROM rated;

ALTER VIEW public.v_commission_calculations_core OWNER TO postgres;

COMMENT ON VIEW public.v_commission_calculations_core IS
  'Commission calculations core view. As of Phase 2 derived_staff_paid_primary_role / _remuneration_plan / _employment_type and the rp_paid plan join (which feeds actual_commission_rate) are sale_date-effective via public.staff_profile_at, with COALESCE fallback to current staff_members for any (staff_id, sale_date) not covered by history.';


-- ===========================================================================
-- 3. public.v_sales_transactions_enriched (REPLACED)
--    Adds 3 LATERAL joins (sw_eff, sp_eff, sc_eff) and COALESCEs the 9
--    staff_*_primary_role / _remuneration_plan / _employment_type columns.
--    is_active is intentionally left as the current staff_members value
--    (history table doesn't track it). Downstream assistant_redirect_candidate
--    and commission_owner_candidate_id flip correctly via the effective work
--    role/plan, which is the whole point of this phase.
-- ===========================================================================
CREATE OR REPLACE VIEW public.v_sales_transactions_enriched AS
WITH base AS (
  SELECT
    st.id, st.import_batch_id, st.raw_row_id, st.location_id, st.invoice,
    st.customer_name, st.sale_datetime, st.sale_date, st.day_name,
    st.month_start, st.month_num, st.product_service_name, st.product_master_id,
    st.raw_product_type, st.product_type_actual, st.product_type_short,
    st.commission_product_service, st.quantity, st.price_ex_gst,
    st.price_incl_gst, st.price_gst_component, st.staff_work_name,
    st.staff_work_id, st.staff_work_type, st.staff_paid_name, st.staff_paid_id,
    st.staff_paid_type, st.staff_commission_name, st.staff_commission_id,
    st.staff_commission_type,
    st.assistant_usage_alert AS assistant_usage_alert_source,
    st.staff_work_is_staff_paid, st.invoice_header, st.product_header,
    COALESCE(sw.display_name, NULLIF(TRIM(COALESCE(st.staff_work_name, '')), ''), NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), '')) AS staff_work_display_name,
    COALESCE(sw.full_name,    NULLIF(TRIM(COALESCE(st.staff_work_name, '')), ''), NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), '')) AS staff_work_full_name,
    COALESCE(sw_eff.primary_role,      sw.primary_role)      AS staff_work_primary_role,
    COALESCE(sw_eff.remuneration_plan, sw.remuneration_plan) AS staff_work_remuneration_plan,
    COALESCE(sw_eff.employment_type,   sw.employment_type)   AS staff_work_employment_type,
    sw.is_active AS staff_work_is_active,
    COALESCE(sp.display_name, NULLIF(TRIM(COALESCE(st.staff_paid_name, '')), ''), NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), ''), NULLIF(TRIM(COALESCE(st.staff_work_name, '')), '')) AS staff_paid_display_name,
    COALESCE(sp.full_name,    NULLIF(TRIM(COALESCE(st.staff_paid_name, '')), ''), NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), ''), NULLIF(TRIM(COALESCE(st.staff_work_name, '')), '')) AS staff_paid_full_name,
    COALESCE(sp_eff.primary_role,      sp.primary_role)      AS staff_paid_primary_role,
    COALESCE(sp_eff.remuneration_plan, sp.remuneration_plan) AS staff_paid_remuneration_plan,
    COALESCE(sp_eff.employment_type,   sp.employment_type)   AS staff_paid_employment_type,
    sp.is_active AS staff_paid_is_active,
    COALESCE(sc.display_name, NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), ''), NULLIF(TRIM(COALESCE(st.staff_work_name, '')), '')) AS staff_commission_display_name,
    COALESCE(sc.full_name,    NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), ''), NULLIF(TRIM(COALESCE(st.staff_work_name, '')), '')) AS staff_commission_full_name,
    COALESCE(sc_eff.primary_role,      sc.primary_role)      AS staff_commission_primary_role,
    COALESCE(sc_eff.remuneration_plan, sc.remuneration_plan) AS staff_commission_remuneration_plan,
    COALESCE(sc_eff.employment_type,   sc.employment_type)   AS staff_commission_employment_type,
    sc.is_active AS staff_commission_is_active,
    st.created_at, st.updated_at
  FROM public.sales_transactions st
    LEFT JOIN LATERAL (
      SELECT sm.*
      FROM public.staff_members sm
      WHERE (st.staff_work_id IS NOT NULL AND sm.id = st.staff_work_id)
         OR (st.staff_work_id IS NULL
             AND NULLIF(TRIM(COALESCE(st.staff_work_name, '')), '') IS NOT NULL
             AND lower(TRIM(st.staff_work_name)) = lower(TRIM(sm.display_name))
             AND sm.is_active = true)
      ORDER BY
        CASE
          WHEN st.staff_work_id IS NOT NULL AND sm.id = st.staff_work_id THEN 0
          ELSE 1
        END
      LIMIT 1
    ) sw ON true
    LEFT JOIN LATERAL (
      SELECT sm.*
      FROM public.staff_members sm
      WHERE (st.staff_paid_id IS NOT NULL AND sm.id = st.staff_paid_id)
         OR (st.staff_paid_id IS NULL
             AND NULLIF(TRIM(COALESCE(st.staff_paid_name, '')), '') IS NOT NULL
             AND lower(TRIM(st.staff_paid_name)) = lower(TRIM(sm.display_name))
             AND sm.is_active = true)
      ORDER BY
        CASE
          WHEN st.staff_paid_id IS NOT NULL AND sm.id = st.staff_paid_id THEN 0
          ELSE 1
        END
      LIMIT 1
    ) sp ON true
    LEFT JOIN LATERAL (
      SELECT sm.*
      FROM public.staff_members sm
      WHERE (st.staff_commission_id IS NOT NULL AND sm.id = st.staff_commission_id)
         OR (st.staff_commission_id IS NULL
             AND NULLIF(TRIM(COALESCE(st.staff_commission_name, '')), '') IS NOT NULL
             AND lower(TRIM(st.staff_commission_name)) = lower(TRIM(sm.display_name))
             AND sm.is_active = true)
      ORDER BY
        CASE
          WHEN st.staff_commission_id IS NOT NULL AND sm.id = st.staff_commission_id THEN 0
          ELSE 1
        END
      LIMIT 1
    ) sc ON true
    -- Effective-dated overlays. The COALESCE on staff id covers the
    -- name-only fallback case too.
    LEFT JOIN LATERAL public.staff_profile_at(
      COALESCE(st.staff_work_id, sw.id),
      st.sale_date
    ) sw_eff ON true
    LEFT JOIN LATERAL public.staff_profile_at(
      COALESCE(st.staff_paid_id, sp.id),
      st.sale_date
    ) sp_eff ON true
    LEFT JOIN LATERAL public.staff_profile_at(
      COALESCE(st.staff_commission_id, sc.id),
      st.sale_date
    ) sc_eff ON true
),
classified AS (
  SELECT
    b.*,
    CASE
      WHEN COALESCE(lower(TRIM(b.commission_product_service)), '') LIKE '%service%' THEN 'service'::text
      WHEN COALESCE(lower(TRIM(b.commission_product_service)), '') LIKE '%retail%'  THEN 'retail'::text
      WHEN COALESCE(lower(TRIM(b.product_type_actual)), '')        LIKE '%service%' THEN 'service'::text
      WHEN COALESCE(lower(TRIM(b.product_type_short)), '')         LIKE '%service%' THEN 'service'::text
      WHEN COALESCE(lower(TRIM(b.raw_product_type)), '')           LIKE '%service%' THEN 'service'::text
      ELSE 'other'::text
    END AS transaction_class,
    CASE WHEN COALESCE(lower(TRIM(b.staff_work_primary_role)), '')       = 'assistant' THEN true ELSE false END AS is_assistant_work,
    CASE WHEN COALESCE(lower(TRIM(b.staff_paid_primary_role)), '')       = 'assistant' THEN true ELSE false END AS is_assistant_paid,
    CASE WHEN COALESCE(lower(TRIM(b.staff_commission_primary_role)), '') = 'assistant' THEN true ELSE false END AS is_assistant_commission,
    CASE WHEN COALESCE(lower(TRIM(b.staff_work_remuneration_plan)), '') = 'wage' THEN true ELSE false END AS is_waged_work_staff,
    CASE WHEN COALESCE(lower(TRIM(b.staff_paid_remuneration_plan)), '') = 'wage' THEN true ELSE false END AS is_waged_paid_staff,
    CASE
      WHEN (b.staff_work_id IS NOT NULL) AND (b.staff_paid_id IS NOT NULL)
       AND (b.staff_work_id <> b.staff_paid_id) THEN true
      ELSE false
    END AS work_paid_mismatch,
    CASE
      WHEN (b.staff_work_id IS NOT NULL) AND (b.staff_commission_id IS NOT NULL)
       AND (b.staff_work_id <> b.staff_commission_id) THEN true
      ELSE false
    END AS work_commission_mismatch,
    CASE
      WHEN (b.staff_work_id IS NOT NULL)
       AND (COALESCE(lower(TRIM(b.staff_work_primary_role)), '')       = 'assistant')
       AND (COALESCE(lower(TRIM(b.staff_work_remuneration_plan)), '')  = 'wage')
       AND (
             ((b.staff_paid_id IS NOT NULL) AND (b.staff_work_id <> b.staff_paid_id))
          OR ((b.staff_paid_id IS NULL) AND (b.staff_commission_id IS NOT NULL) AND (b.staff_work_id <> b.staff_commission_id))
       )
      THEN true
      ELSE false
    END AS assistant_redirect_candidate,
    CASE
      WHEN (b.staff_work_id IS NULL) AND (NULLIF(TRIM(COALESCE(b.staff_work_name, '')), '') IS NOT NULL)             THEN 'unmatched_work_staff'::text
      WHEN (b.staff_paid_id IS NULL) AND (NULLIF(TRIM(COALESCE(b.staff_paid_name, '')), '') IS NOT NULL)             THEN 'unmatched_paid_staff'::text
      WHEN (b.staff_commission_id IS NULL) AND (NULLIF(TRIM(COALESCE(b.staff_commission_name, '')), '') IS NOT NULL) THEN 'unmatched_commission_staff'::text
      WHEN (b.staff_work_id IS NOT NULL)
       AND (COALESCE(lower(TRIM(b.staff_work_primary_role)), '')       = 'assistant')
       AND (COALESCE(lower(TRIM(b.staff_work_remuneration_plan)), '')  = 'wage')
       AND (
             ((b.staff_paid_id IS NOT NULL) AND (b.staff_work_id <> b.staff_paid_id))
          OR ((b.staff_paid_id IS NULL) AND (b.staff_commission_id IS NOT NULL) AND (b.staff_work_id <> b.staff_commission_id))
       )
      THEN 'assistant_work_redirect_candidate'::text
      WHEN (b.staff_work_id IS NOT NULL) AND (b.staff_paid_id IS NOT NULL) AND (b.staff_work_id <> b.staff_paid_id) THEN 'work_paid_mismatch'::text
      ELSE NULL::text
    END AS review_flag
  FROM base b
)
SELECT
  id, import_batch_id, raw_row_id, location_id, invoice, customer_name,
  sale_datetime, sale_date, day_name, month_start, month_num,
  product_service_name, product_master_id, raw_product_type,
  product_type_actual, product_type_short, commission_product_service,
  quantity, price_ex_gst, price_incl_gst, price_gst_component,
  staff_work_name, staff_work_id, staff_work_type, staff_paid_name,
  staff_paid_id, staff_paid_type, staff_commission_name, staff_commission_id,
  staff_commission_type, assistant_usage_alert_source, staff_work_is_staff_paid,
  invoice_header, product_header, staff_work_display_name, staff_work_full_name,
  staff_work_primary_role, staff_work_remuneration_plan, staff_work_employment_type,
  staff_work_is_active, staff_paid_display_name, staff_paid_full_name,
  staff_paid_primary_role, staff_paid_remuneration_plan, staff_paid_employment_type,
  staff_paid_is_active, staff_commission_display_name, staff_commission_full_name,
  staff_commission_primary_role, staff_commission_remuneration_plan,
  staff_commission_employment_type, staff_commission_is_active, created_at,
  updated_at, transaction_class, is_assistant_work, is_assistant_paid,
  is_assistant_commission, is_waged_work_staff, is_waged_paid_staff,
  work_paid_mismatch, work_commission_mismatch, assistant_redirect_candidate,
  review_flag,
  CASE
    WHEN assistant_redirect_candidate THEN COALESCE(staff_paid_id, staff_commission_id)
    WHEN staff_commission_id IS NOT NULL THEN staff_commission_id
    WHEN staff_paid_id IS NOT NULL       THEN staff_paid_id
    ELSE staff_work_id
  END AS commission_owner_candidate_id,
  CASE
    WHEN assistant_redirect_candidate THEN COALESCE(staff_paid_display_name, staff_commission_display_name)
    WHEN staff_commission_id IS NOT NULL THEN staff_commission_display_name
    WHEN staff_paid_id IS NOT NULL       THEN staff_paid_display_name
    ELSE staff_work_display_name
  END AS commission_owner_candidate_name,
  CASE
    WHEN assistant_redirect_candidate THEN 'assistant_work_redirected_to_paid_staff'::text
    WHEN staff_commission_id IS NOT NULL THEN 'explicit_commission_staff'::text
    WHEN staff_paid_id IS NOT NULL       THEN 'paid_staff_fallback'::text
    WHEN staff_work_id IS NOT NULL       THEN 'work_staff_fallback'::text
    ELSE 'unassigned'::text
  END AS commission_owner_rule
FROM classified c;

ALTER VIEW public.v_sales_transactions_enriched OWNER TO postgres;

COMMENT ON VIEW public.v_sales_transactions_enriched IS
  'Enriched sales view (KPI / drilldown source). As of Phase 2 the 9 staff_(work|paid|commission)_(primary_role|remuneration_plan|employment_type) columns are derived from public.staff_role_assignments effective at sale_date, with COALESCE fallback to current staff_members. Downstream assistant_redirect_candidate / commission_owner_candidate_id / commission_owner_candidate_name flip to historically correct attribution automatically.';


-- ===========================================================================
-- 4. public.get_staff_fte_for_kpi_display — DROP single-arg, RECREATE with
--    optional p_period_end_date (defaulting to current_date so existing
--    callers using {p_staff_member_id} continue to work unchanged via
--    PostgREST's named-arg + DEFAULT resolution).
-- ===========================================================================
DROP FUNCTION IF EXISTS public.get_staff_fte_for_kpi_display(uuid);

CREATE OR REPLACE FUNCTION public.get_staff_fte_for_kpi_display(
  p_staff_member_id  uuid,
  p_period_end_date  date DEFAULT current_date
)
RETURNS numeric
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public, auth, pg_temp
AS $fn$
DECLARE
  v_role text;
  v_self uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not authenticated' USING ERRCODE = '28000';
  END IF;

  IF p_staff_member_id IS NULL THEN
    RETURN NULL;
  END IF;

  v_role := private.kpi_caller_access_role();
  IF v_role IS NULL THEN
    RAISE EXCEPTION 'no active access mapping for caller'
      USING ERRCODE = '42501';
  END IF;

  IF v_role IN ('stylist', 'assistant') THEN
    v_self := private.kpi_caller_staff_member_id();
    IF v_self IS NULL OR p_staff_member_id IS DISTINCT FROM v_self THEN
      RAISE EXCEPTION 'not authorized'
        USING ERRCODE = '42501';
    END IF;
  ELSIF v_role NOT IN ('admin', 'superadmin', 'manager') THEN
    RAISE EXCEPTION 'not authorized'
      USING ERRCODE = '42501';
  END IF;

  -- Effective-dated FTE at p_period_end_date with COALESCE fallback
  -- to current staff_members.fte. When p_period_end_date defaults to
  -- current_date the answer equals the open-ended backfilled row
  -- (which mirrors staff_members.fte) → no behavioural change for
  -- existing callers.
  RETURN (
    SELECT COALESCE(spe.fte, sm.fte)
    FROM public.staff_members sm
    LEFT JOIN LATERAL public.staff_profile_at(sm.id, p_period_end_date) spe ON true
    WHERE sm.id = p_staff_member_id
    LIMIT 1
  );
END;
$fn$;

ALTER FUNCTION public.get_staff_fte_for_kpi_display(uuid, date) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.get_staff_fte_for_kpi_display(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_staff_fte_for_kpi_display(uuid, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_staff_fte_for_kpi_display(uuid, date) TO service_role;

COMMENT ON FUNCTION public.get_staff_fte_for_kpi_display(uuid, date) IS
  'Returns staff FTE effective at p_period_end_date (default current_date) via public.staff_profile_at, with COALESCE fallback to current staff_members.fte. Stylists/assistants: own staff id only. Admin/manager/superadmin: any id.';


-- ===========================================================================
-- 5. public.get_kpi_stylist_profitability_live (REPLACED)
--    Denominator (FTE) and the cohort eligibility filter (primary_role
--    LIKE '%stylist%' AND fte > 0) now read effective values at
--    v_mtd_through with COALESCE fallback to current staff_members.
--    Voucher exclusion, scope handling, and the value/numerator/denominator
--    formulas are unchanged.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.get_kpi_stylist_profitability_live(
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
  v_numerator    numeric(18, 4);
  v_denominator  numeric(18, 4);
  v_value        numeric(18, 4);
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_stylist_profitability_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  IF v_scope = 'staff' THEN
    SELECT
      COALESCE(SUM(e.price_ex_gst), 0)::numeric(18, 4)
    INTO v_numerator
    FROM public.v_sales_transactions_enriched e
    WHERE e.month_start = v_period_start
      AND e.sale_date  <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
      AND NOT public.is_voucher_sale_row(
        e.raw_product_type, e.product_type_actual,
        e.product_type_short, e.commission_product_service
      )
      AND e.commission_owner_candidate_id = v_staff_id;

    -- Effective-dated FTE for the staff scope. COALESCE keeps today's
    -- value when no covering history row exists.
    SELECT COALESCE(spe.fte, sm.fte)::numeric(18, 4)
      INTO v_denominator
    FROM public.staff_members sm
    LEFT JOIN LATERAL public.staff_profile_at(sm.id, v_mtd_through) spe ON true
    WHERE sm.id = v_staff_id;

  ELSE
    WITH stylist_sales AS (
      SELECT
        e.commission_owner_candidate_id AS sid,
        SUM(e.price_ex_gst)             AS revenue
      FROM public.v_sales_transactions_enriched e
      WHERE e.month_start = v_period_start
        AND e.sale_date  <= v_mtd_through
        AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
        AND NOT public.is_voucher_sale_row(
          e.raw_product_type, e.product_type_actual,
          e.product_type_short, e.commission_product_service
        )
        AND e.commission_owner_candidate_id IS NOT NULL
        AND (
          v_scope = 'business'
          OR (v_scope = 'location' AND e.location_id = v_loc_id)
        )
      GROUP BY e.commission_owner_candidate_id
    ),
    eligible AS (
      SELECT
        ss.revenue,
        COALESCE(spe.fte, sm.fte)::numeric(18, 4) AS fte
      FROM stylist_sales ss
      JOIN public.staff_members sm ON sm.id = ss.sid
      LEFT JOIN LATERAL public.staff_profile_at(sm.id, v_mtd_through) spe ON true
      -- Substring match so 'Senior Stylist', 'Director Stylist', etc.
      -- all qualify. NULL stays excluded.
      WHERE COALESCE(lower(btrim(COALESCE(spe.primary_role, sm.primary_role))), '') LIKE '%stylist%'
        AND COALESCE(spe.fte, sm.fte) IS NOT NULL
        AND COALESCE(spe.fte, sm.fte) > 0
    )
    SELECT
      COALESCE(SUM(revenue), 0)::numeric(18, 4),
      COALESCE(SUM(fte),     0)::numeric(18, 4)
    INTO v_numerator, v_denominator
    FROM eligible;
  END IF;

  v_value := CASE
               WHEN v_denominator IS NOT NULL AND v_denominator > 0
                 THEN (v_numerator / v_denominator)::numeric(18, 4)
               ELSE NULL
             END;

  RETURN QUERY
  SELECT
    'stylist_profitability'::text                                                                                                                                                                                  AS kpi_code,
    v_scope                                                                                                                                                                                                        AS scope_type,
    v_loc_id                                                                                                                                                                                                       AS location_id,
    v_staff_id                                                                                                                                                                                                     AS staff_member_id,
    v_period_start                                                                                                                                                                                                 AS period_start,
    v_period_end                                                                                                                                                                                                   AS period_end,
    v_mtd_through                                                                                                                                                                                                  AS mtd_through,
    v_is_current                                                                                                                                                                                                   AS is_current_open_month,
    v_value                                                                                                                                                                                                        AS value,
    v_numerator                                                                                                                                                                                                    AS value_numerator,
    v_denominator                                                                                                                                                                                                  AS value_denominator,
    'v_sales_transactions_enriched revenue / effective FTE (staff_profile_at COALESCE staff_members); non-internal; vouchers excluded; effective primary_role ILIKE %stylist% & fte>0 at rollup; commission_owner_candidate_id attribution'::text AS source;
END;
$fn$;

ALTER FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_stylist_profitability_live(date, text, uuid, uuid) IS
  'Live stylist profitability KPI (NZD per FTE). Numerator = eligible stylists'' sales ex GST (vouchers excluded). Denominator = effective FTE at v_mtd_through via public.staff_profile_at with COALESCE fallback to staff_members.fte. Cohort eligibility uses effective primary_role at v_mtd_through.';


-- ===========================================================================
-- 6. public.get_kpi_stylist_comparisons_live (REPLACED)
--    cohort CTE now reads effective primary_role / fte at v_mtd_through.
--    is_active continues to read current staff_members (history doesn't
--    track activity, and an inactive staff member should drop out of the
--    cohort comparison regardless of their historical role).
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.get_kpi_stylist_comparisons_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'staff',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code              text,
  period_start          date,
  period_end            date,
  mtd_through           date,
  is_current_open_month boolean,
  staff_member_id       uuid,
  current_value         numeric(18, 4),
  highest_value         numeric(18, 4),
  average_value         numeric(18, 4),
  cohort_size           integer,
  is_highest            boolean,
  is_above_average      boolean
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
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_stylist_comparisons_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_is_current  := (v_period_start = date_trunc('month', current_date)::date);
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  IF v_scope <> 'staff' OR v_staff_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH cohort AS (
    SELECT
      sm.id                       AS staff_id,
      COALESCE(spe.fte, sm.fte)   AS staff_fte
    FROM public.staff_members sm
    LEFT JOIN LATERAL public.staff_profile_at(sm.id, v_mtd_through) spe ON true
    WHERE sm.is_active = true
      AND COALESCE(lower(btrim(COALESCE(spe.primary_role, sm.primary_role))), '') LIKE '%stylist%'
  ),
  month_e AS (
    SELECT
      e.commission_owner_candidate_id AS staff_id,
      e.price_ex_gst,
      e.customer_name,
      e.assistant_redirect_candidate,
      public.is_voucher_sale_row(
        e.raw_product_type, e.product_type_actual,
        e.product_type_short, e.commission_product_service
      ) AS is_voucher
    FROM public.v_sales_transactions_enriched e
    INNER JOIN cohort c ON c.staff_id = e.commission_owner_candidate_id
    WHERE e.month_start = v_period_start
      AND e.sale_date <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  rev AS (
    SELECT
      me.staff_id,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE NOT me.is_voucher),
        0
      )::numeric(18, 4) AS v
    FROM month_e me
    GROUP BY me.staff_id
  ),
  gst AS (
    SELECT
      me.staff_id,
      COUNT(DISTINCT public.normalise_customer_name(me.customer_name))::numeric(18, 4) AS v
    FROM month_e me
    WHERE public.normalise_customer_name(me.customer_name) IS NOT NULL
    GROUP BY me.staff_id
  ),
  asst_util AS (
    SELECT
      me.staff_id,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE me.assistant_redirect_candidate AND NOT me.is_voucher),
        0
      )::numeric(18, 4) AS numer,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE NOT me.is_voucher),
        0
      )::numeric(18, 4) AS denom
    FROM month_e me
    GROUP BY me.staff_id
  ),
  cohort_metrics AS (
    SELECT
      c.staff_id,
      c.staff_fte,
      COALESCE(r.v, 0::numeric(18, 4)) AS revenue,
      COALESCE(g.v, 0::numeric(18, 4)) AS guests,
      CASE
        WHEN COALESCE(g.v, 0::numeric(18, 4)) > 0 THEN
          (COALESCE(r.v, 0::numeric(18, 4)) / g.v)::numeric(18, 4)
        ELSE NULL::numeric(18, 4)
      END AS avg_spend
    FROM cohort c
    LEFT JOIN rev r ON r.staff_id = c.staff_id
    LEFT JOIN gst g ON g.staff_id = c.staff_id
  ),
  cohort_asst AS (
    SELECT
      c.staff_id,
      CASE
        WHEN COALESCE(au.denom, 0::numeric(18, 4)) > 0 THEN
          (COALESCE(au.numer, 0::numeric(18, 4)) / au.denom)::numeric(18, 4)
        ELSE NULL::numeric(18, 4)
      END AS util_ratio
    FROM cohort c
    LEFT JOIN asst_util au ON au.staff_id = c.staff_id
  ),
  month_norms AS (
    SELECT DISTINCT
      me.staff_id,
      public.normalise_customer_name(me.customer_name) AS norm_name
    FROM month_e me
    WHERE public.normalise_customer_name(me.customer_name) IS NOT NULL
  ),
  newc AS (
    SELECT
      mn.staff_id,
      (COUNT(*)::numeric(18, 4)) AS v
    FROM month_norms mn
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_period_start
        AND public.normalise_customer_name(e2.customer_name) = mn.norm_name
    )
    GROUP BY mn.staff_id
  ),
  per_stylist AS (
    SELECT
      'revenue'::text AS kpi_code,
      cm.staff_id,
      (
        CASE
          WHEN cm.staff_fte IS NOT NULL
           AND cm.staff_fte::numeric > 0
           AND cm.staff_fte::numeric < 1
          THEN (cm.revenue / cm.staff_fte::numeric)::numeric(18, 4)
          ELSE cm.revenue
        END
      ) AS v
    FROM cohort_metrics cm
    UNION ALL
    SELECT
      'guests_per_month'::text,
      cm.staff_id,
      (
        CASE
          WHEN cm.staff_fte IS NOT NULL
           AND cm.staff_fte::numeric > 0
           AND cm.staff_fte::numeric < 1
          THEN (cm.guests / cm.staff_fte::numeric)::numeric(18, 4)
          ELSE cm.guests
        END
      ) AS v
    FROM cohort_metrics cm
    UNION ALL
    SELECT
      'new_clients_per_month'::text,
      c.staff_id,
      (
        CASE
          WHEN c.staff_fte IS NOT NULL
           AND c.staff_fte::numeric > 0
           AND c.staff_fte::numeric < 1
          THEN (COALESCE(n.v, 0::numeric(18, 4)) / c.staff_fte::numeric)::numeric(18, 4)
          ELSE COALESCE(n.v, 0::numeric(18, 4))
        END
      ) AS v
    FROM cohort c
    LEFT JOIN newc n ON n.staff_id = c.staff_id
    UNION ALL
    SELECT 'average_client_spend'::text, cm.staff_id, cm.avg_spend
    FROM cohort_metrics cm
    UNION ALL
    SELECT 'assistant_utilisation_ratio'::text, ca.staff_id, ca.util_ratio
    FROM cohort_asst ca
  ),
  agg AS (
    SELECT
      p.kpi_code,
      MAX(p.v) FILTER (WHERE p.v IS NOT NULL)            AS highest,
      AVG(p.v) FILTER (WHERE p.v IS NOT NULL)            AS avg_v,
      (COUNT(*) FILTER (WHERE p.v IS NOT NULL))::integer AS cohort_count,
      MAX(p.v) FILTER (WHERE p.staff_id = v_staff_id)    AS current_v
    FROM per_stylist p
    GROUP BY p.kpi_code
  )
  SELECT
    a.kpi_code                              AS kpi_code,
    v_period_start                          AS period_start,
    v_period_end                            AS period_end,
    v_mtd_through                           AS mtd_through,
    v_is_current                            AS is_current_open_month,
    v_staff_id                              AS staff_member_id,
    a.current_v::numeric(18, 4)             AS current_value,
    a.highest::numeric(18, 4)               AS highest_value,
    a.avg_v::numeric(18, 4)                 AS average_value,
    a.cohort_count                          AS cohort_size,
    (
      a.cohort_count >= 2
      AND a.current_v IS NOT NULL
      AND a.highest   IS NOT NULL
      AND a.current_v >= a.highest
    )                                       AS is_highest,
    (
      a.cohort_count >= 2
      AND a.current_v IS NOT NULL
      AND a.avg_v     IS NOT NULL
      AND a.current_v >  a.avg_v
    )                                       AS is_above_average
  FROM agg a
  ORDER BY a.kpi_code;
END;
$fn$;

ALTER FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_stylist_comparisons_live(date, text, uuid, uuid) IS
  'Live stylist comparison for staff/self KPI cards. Cohort primary_role / fte effective at v_mtd_through (staff_profile_at COALESCE staff_members). Voucher exclusion preserved. Guests / new_clients counts intentionally include voucher-only guests.';


-- ===========================================================================
-- 7. public.get_kpi_stylist_comparison_leaders_live (REPLACED)
--    Mirrors comparisons_live cohort filtering so "Top stylist" badges
--    are consistent.
-- ===========================================================================
CREATE OR REPLACE FUNCTION public.get_kpi_stylist_comparison_leaders_live(
  p_period_start    date  DEFAULT NULL,
  p_scope           text  DEFAULT 'staff',
  p_location_id     uuid  DEFAULT NULL,
  p_staff_member_id uuid  DEFAULT NULL
)
RETURNS TABLE (
  kpi_code               text,
  top_staff_member_id    uuid,
  top_staff_display_name text
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
  v_scope        text;
  v_loc_id       uuid;
  v_staff_id     uuid;
BEGIN
  v_period_start := COALESCE(p_period_start, date_trunc('month', current_date)::date);

  IF v_period_start <> date_trunc('month', v_period_start)::date THEN
    RAISE EXCEPTION
      'get_kpi_stylist_comparison_leaders_live: p_period_start must be the 1st of a month, got %',
      v_period_start
      USING ERRCODE = '22023';
  END IF;

  v_period_end  := (v_period_start + interval '1 month - 1 day')::date;
  v_mtd_through := LEAST(v_period_end, current_date);

  SELECT s.scope_type, s.location_id, s.staff_member_id
    INTO v_scope, v_loc_id, v_staff_id
  FROM private.kpi_resolve_scope(p_scope, p_location_id, p_staff_member_id) s;

  IF v_scope <> 'staff' OR v_staff_id IS NULL THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH cohort AS (
    SELECT
      sm.id                       AS staff_id,
      COALESCE(spe.fte, sm.fte)   AS staff_fte
    FROM public.staff_members sm
    LEFT JOIN LATERAL public.staff_profile_at(sm.id, v_mtd_through) spe ON true
    WHERE sm.is_active = true
      AND COALESCE(lower(btrim(COALESCE(spe.primary_role, sm.primary_role))), '') LIKE '%stylist%'
  ),
  month_e AS (
    SELECT
      e.commission_owner_candidate_id AS staff_id,
      e.price_ex_gst,
      e.customer_name,
      e.assistant_redirect_candidate,
      public.is_voucher_sale_row(
        e.raw_product_type, e.product_type_actual,
        e.product_type_short, e.commission_product_service
      ) AS is_voucher
    FROM public.v_sales_transactions_enriched e
    INNER JOIN cohort c ON c.staff_id = e.commission_owner_candidate_id
    WHERE e.month_start = v_period_start
      AND e.sale_date <= v_mtd_through
      AND COALESCE(lower(btrim(e.commission_owner_candidate_name)), '') <> 'internal'
  ),
  rev AS (
    SELECT
      me.staff_id,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE NOT me.is_voucher),
        0
      )::numeric(18, 4) AS v
    FROM month_e me
    GROUP BY me.staff_id
  ),
  gst AS (
    SELECT
      me.staff_id,
      COUNT(DISTINCT public.normalise_customer_name(me.customer_name))::numeric(18, 4) AS v
    FROM month_e me
    WHERE public.normalise_customer_name(me.customer_name) IS NOT NULL
    GROUP BY me.staff_id
  ),
  asst_util AS (
    SELECT
      me.staff_id,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE me.assistant_redirect_candidate AND NOT me.is_voucher),
        0
      )::numeric(18, 4) AS numer,
      COALESCE(
        SUM(me.price_ex_gst) FILTER (WHERE NOT me.is_voucher),
        0
      )::numeric(18, 4) AS denom
    FROM month_e me
    GROUP BY me.staff_id
  ),
  cohort_metrics AS (
    SELECT
      c.staff_id,
      c.staff_fte,
      COALESCE(r.v, 0::numeric(18, 4)) AS revenue,
      COALESCE(g.v, 0::numeric(18, 4)) AS guests,
      CASE
        WHEN COALESCE(g.v, 0::numeric(18, 4)) > 0 THEN
          (COALESCE(r.v, 0::numeric(18, 4)) / g.v)::numeric(18, 4)
        ELSE NULL::numeric(18, 4)
      END AS avg_spend
    FROM cohort c
    LEFT JOIN rev r ON r.staff_id = c.staff_id
    LEFT JOIN gst g ON g.staff_id = c.staff_id
  ),
  cohort_asst AS (
    SELECT
      c.staff_id,
      CASE
        WHEN COALESCE(au.denom, 0::numeric(18, 4)) > 0 THEN
          (COALESCE(au.numer, 0::numeric(18, 4)) / au.denom)::numeric(18, 4)
        ELSE NULL::numeric(18, 4)
      END AS util_ratio
    FROM cohort c
    LEFT JOIN asst_util au ON au.staff_id = c.staff_id
  ),
  month_norms AS (
    SELECT DISTINCT
      me.staff_id,
      public.normalise_customer_name(me.customer_name) AS norm_name
    FROM month_e me
    WHERE public.normalise_customer_name(me.customer_name) IS NOT NULL
  ),
  newc AS (
    SELECT
      mn.staff_id,
      (COUNT(*)::numeric(18, 4)) AS v
    FROM month_norms mn
    WHERE NOT EXISTS (
      SELECT 1
      FROM public.v_sales_transactions_enriched e2
      WHERE e2.sale_date < v_period_start
        AND public.normalise_customer_name(e2.customer_name) = mn.norm_name
    )
    GROUP BY mn.staff_id
  ),
  per_stylist AS (
    SELECT
      'revenue'::text AS kpi_code,
      cm.staff_id,
      (
        CASE
          WHEN cm.staff_fte IS NOT NULL
           AND cm.staff_fte::numeric > 0
           AND cm.staff_fte::numeric < 1
          THEN (cm.revenue / cm.staff_fte::numeric)::numeric(18, 4)
          ELSE cm.revenue
        END
      ) AS v
    FROM cohort_metrics cm
    UNION ALL
    SELECT
      'guests_per_month'::text,
      cm.staff_id,
      (
        CASE
          WHEN cm.staff_fte IS NOT NULL
           AND cm.staff_fte::numeric > 0
           AND cm.staff_fte::numeric < 1
          THEN (cm.guests / cm.staff_fte::numeric)::numeric(18, 4)
          ELSE cm.guests
        END
      ) AS v
    FROM cohort_metrics cm
    UNION ALL
    SELECT
      'new_clients_per_month'::text,
      c.staff_id,
      (
        CASE
          WHEN c.staff_fte IS NOT NULL
           AND c.staff_fte::numeric > 0
           AND c.staff_fte::numeric < 1
          THEN (COALESCE(n.v, 0::numeric(18, 4)) / c.staff_fte::numeric)::numeric(18, 4)
          ELSE COALESCE(n.v, 0::numeric(18, 4))
        END
      ) AS v
    FROM cohort c
    LEFT JOIN newc n ON n.staff_id = c.staff_id
    UNION ALL
    SELECT 'average_client_spend'::text, cm.staff_id, cm.avg_spend
    FROM cohort_metrics cm
    UNION ALL
    SELECT 'assistant_utilisation_ratio'::text, ca.staff_id, ca.util_ratio
    FROM cohort_asst ca
  ),
  agg AS (
    SELECT
      p.kpi_code,
      MAX(p.v) FILTER (WHERE p.v IS NOT NULL) AS highest
    FROM per_stylist p
    GROUP BY p.kpi_code
  ),
  top_by_kpi AS (
    SELECT DISTINCT ON (p.kpi_code)
      p.kpi_code,
      p.staff_id AS top_staff_member_id
    FROM per_stylist p
    INNER JOIN agg a ON a.kpi_code = p.kpi_code
      AND a.highest IS NOT NULL
      AND p.v IS NOT NULL
      AND p.v = a.highest
    ORDER BY p.kpi_code, p.staff_id
  ),
  top_named AS (
    SELECT
      tb.kpi_code,
      tb.top_staff_member_id,
      COALESCE(
        NULLIF(btrim(COALESCE(sm.display_name, '')), ''),
        NULLIF(btrim(COALESCE(sm.full_name, '')), ''),
        'Staff'::text
      ) AS top_staff_display_name
    FROM top_by_kpi tb
    LEFT JOIN public.staff_members sm ON sm.id = tb.top_staff_member_id
  )
  SELECT
    k.kpi_code,
    tn.top_staff_member_id,
    tn.top_staff_display_name
  FROM (
    VALUES
      ('revenue'::text),
      ('guests_per_month'::text),
      ('new_clients_per_month'::text),
      ('average_client_spend'::text),
      ('assistant_utilisation_ratio'::text)
  ) AS k(kpi_code)
  LEFT JOIN top_named tn ON tn.kpi_code = k.kpi_code
  ORDER BY k.kpi_code;
END;
$fn$;

ALTER FUNCTION public.get_kpi_stylist_comparison_leaders_live(date, text, uuid, uuid) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.get_kpi_stylist_comparison_leaders_live(date, text, uuid, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_comparison_leaders_live(date, text, uuid, uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_kpi_stylist_comparison_leaders_live(date, text, uuid, uuid) TO service_role;

COMMENT ON FUNCTION public.get_kpi_stylist_comparison_leaders_live(date, text, uuid, uuid) IS
  'Cohort leader per KPI for staff-scope comparisons. Cohort primary_role / fte effective at v_mtd_through (staff_profile_at COALESCE staff_members). Mirrors get_kpi_stylist_comparisons_live filters. One row per KPI code.';
