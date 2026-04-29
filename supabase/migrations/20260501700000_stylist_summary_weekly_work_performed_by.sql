-- Expose admin summary `work_performed_by` on stylist My Sales RPC
-- (`get_my_commission_summary_weekly` → `v_stylist_commission_summary_weekly_final`).

CREATE OR REPLACE VIEW public.v_stylist_commission_summary_weekly_final AS
 SELECT a.user_id,
    w.pay_week_start,
    w.pay_week_end,
    w.pay_date,
    w.location_id,
    w.derived_staff_paid_id,
    w.derived_staff_paid_display_name,
    w.derived_staff_paid_full_name,
    w.derived_staff_paid_remuneration_plan,
    w.line_count,
    w.payable_line_count,
    w.expected_no_commission_line_count,
    w.zero_value_line_count,
    w.review_line_count,
    w.total_sales_ex_gst,
    w.total_actual_commission_ex_gst,
    w.total_theoretical_commission_ex_gst,
    w.total_assistant_commission_ex_gst,
    w.unconfigured_paid_staff_line_count,
    w.has_unconfigured_paid_staff_rows,
    a.access_role,
    w.location_name,
    w.work_performed_by
   FROM public.v_admin_payroll_summary_weekly w
     JOIN public.staff_member_user_access a ON a.is_active = true
       AND (
         (a.access_role = ANY (ARRAY['stylist'::text, 'assistant'::text])
           AND a.staff_member_id = w.derived_staff_paid_id)
         OR a.access_role = ANY (ARRAY['manager'::text, 'admin'::text])
       )
  WHERE w.derived_staff_paid_id IS NOT NULL
    AND COALESCE(lower(TRIM(BOTH FROM w.derived_staff_paid_display_name)), ''::text) <> 'internal'::text
    AND w.has_unconfigured_paid_staff_rows = false;
