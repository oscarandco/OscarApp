CREATE OR REPLACE FUNCTION public.get_my_sales_trend_weekly()
 RETURNS TABLE(staff_member_id uuid, staff_display_name text, staff_full_name text, pay_week_start date, pay_week_end date, pay_date date, effective_primary_role text, effective_remuneration_plan text, total_sales_ex_gst numeric, total_actual_commission_ex_gst numeric, total_theoretical_commission_ex_gst numeric, total_assistant_commission_ex_gst numeric, total_theoretical_assistant_commission_ex_gst numeric, assistant_commission_contributors jsonb)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
SET jit TO 'off'
AS $function$
  WITH me AS (
    SELECT a.staff_member_id
    FROM public.staff_member_user_access a
    WHERE a.user_id = auth.uid()
      AND COALESCE(a.is_active, false) = true
      AND a.staff_member_id IS NOT NULL
    LIMIT 1
  ),
  scoped_sale_ids AS MATERIALIZED (
 SELECT DISTINCT p.id FROM public.v_sales_transactions_powerbi_parity p
 JOIN public.staff_members s ON
 (p.staff_paid_name_derived IS NOT NULL AND lower(trim(p.staff_paid_name_derived))=lower(trim(s.display_name)))
 OR (p.staff_paid_name_derived IS NULL AND p.staff_work_id IS NOT NULL AND p.staff_work_is_staff_paid_dax_parity='Yes' AND s.id=p.staff_work_id)
 JOIN me ON me.staff_member_id=s.id
 WHERE p.sale_date >= current_date-INTERVAL '54 weeks'
 ),
 scoped_lines AS MATERIALIZED (
 SELECT c.derived_staff_paid_id,c.derived_staff_paid_display_name,c.derived_staff_paid_full_name,
 c.sale_date,date_trunc('week',c.sale_date::timestamp)::date pay_week_start,
 date_trunc('week',c.sale_date::timestamp)::date+6 pay_week_end,
 date_trunc('week',c.sale_date::timestamp)::date+10 pay_date,
 c.raw_product_type,c.product_type_actual_derived AS product_type_actual,
 c.product_type_short_derived AS product_type_short,c.commission_product_service_derived AS commission_product_service,
 c.price_ex_gst,c.actual_commission_amt_ex_gst,c.theoretical_commission_amt_ex_gst,
 c.assistant_commission_amt_ex_gst,c.theoretical_assistant_commission_amt_ex_gst,
 c.staff_work_id,c.work_display_name,c.work_full_name
 FROM scoped_sale_ids i CROSS JOIN LATERAL (
 SELECT core.* FROM public.v_commission_calculations_core core
 WHERE core.id=i.id AND core.derived_staff_paid_id=(SELECT staff_member_id FROM me) OFFSET 0
 ) c
 WHERE c.sale_date >= (current_date-INTERVAL '54 weeks')
 ),
 weekly AS (
    -- One row per (staff, pay_week) combined across locations. Same
    -- voucher exclusion as v_admin_payroll_summary_weekly.total_sales_ex_gst.
    --
    -- Hard-bounded to the last 54 weeks of sale_date (52 visible + 2
    -- weeks alignment buffer). This is the main perf guardrail: with
    -- the underlying sales_transactions(sale_date) index it keeps the
    -- scan from walking historical data the page will never show.
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
      ROUND(SUM(COALESCE(l.actual_commission_amt_ex_gst,             0::numeric)), 2) AS total_actual_commission_ex_gst,
      ROUND(SUM(COALESCE(l.theoretical_commission_amt_ex_gst,        0::numeric)), 2) AS total_theoretical_commission_ex_gst,
      ROUND(SUM(COALESCE(l.assistant_commission_amt_ex_gst,          0::numeric)), 2) AS total_assistant_commission_ex_gst,
      ROUND(SUM(COALESCE(l.theoretical_assistant_commission_amt_ex_gst, 0::numeric)), 2)
        AS total_theoretical_assistant_commission_ex_gst
    FROM scoped_lines l
    JOIN me ON me.staff_member_id = l.derived_staff_paid_id
    WHERE l.sale_date >= (current_date - INTERVAL '54 weeks')
    GROUP BY l.derived_staff_paid_id, l.pay_week_start
  ),
  contrib_actual AS (
    -- Actual assistant breakdown sourced from the same payroll line
    -- rows that contribute to total_assistant_commission_ex_gst.
    -- Restricted to the same 54-week window as weekly so this CTE
    -- can't outgrow the main pass.
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
    FROM scoped_lines l
    JOIN me ON me.staff_member_id = l.derived_staff_paid_id
    WHERE l.sale_date >= (current_date - INTERVAL '54 weeks')
      AND COALESCE(l.assistant_commission_amt_ex_gst, 0::numeric) > 0::numeric
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
  contrib_actual_agg AS (
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
    FROM contrib_actual c
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
  LEFT JOIN contrib_actual_agg ca
    ON ca.staff_member_id = w.staff_member_id
   AND ca.pay_week_start  = w.pay_week_start
  ORDER BY w.pay_week_start DESC;
$function$;
