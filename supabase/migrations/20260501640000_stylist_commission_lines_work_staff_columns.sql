-- Expose work-performed and staff-paid attribution columns on stylist line RPC
-- (same underlying fields as v_admin_payroll_lines_weekly) for My Sales line
-- preview and full week report.

CREATE OR REPLACE VIEW public.v_stylist_commission_lines_weekly_final AS
 SELECT a.user_id,
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
    l.pay_week_start,
    l.pay_week_end,
    l.pay_date,
    l.customer_name,
    l.product_service_name,
    l.work_display_name,
    l.work_full_name,
    l.staff_work_name,
    l.staff_paid_name_derived,
    l.existing_staff_paid_name,
    l.product_type_actual,
    l.product_type_short,
    l.commission_product_service,
    l.commission_category_final,
    l.quantity,
    l.price_ex_gst,
    l.price_incl_gst,
    l.derived_staff_paid_id,
    l.derived_staff_paid_display_name,
    l.derived_staff_paid_full_name,
    l.actual_commission_rate,
    l.actual_commission_amt_ex_gst,
    l.assistant_commission_amt_ex_gst,
    l.payroll_status,
        CASE
            WHEN l.payroll_status = 'expected_no_commission'::text THEN l.calculation_alert
            WHEN l.payroll_status = 'zero_value_commission_row'::text THEN 'zero_commission_row'::text
            ELSE NULL::text
        END AS stylist_visible_note,
    a.access_role,
    l.location_name
   FROM v_admin_payroll_lines_weekly l
     JOIN staff_member_user_access a ON a.is_active = true
       AND (
         (a.access_role = ANY (ARRAY['stylist'::text, 'assistant'::text])
           AND a.staff_member_id = l.derived_staff_paid_id)
         OR a.access_role = ANY (ARRAY['manager'::text, 'admin'::text])
       )
  WHERE l.derived_staff_paid_id IS NOT NULL
    AND COALESCE(lower(TRIM(BOTH FROM l.derived_staff_paid_display_name)), ''::text) <> 'internal'::text
    AND COALESCE(l.calculation_alert, ''::text) <> 'non_commission_unconfigured_paid_staff'::text;
