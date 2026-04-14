-- Replace stored role `self` with `stylist`. Canonical roles: stylist, assistant, manager, admin.
-- `stylist` and `assistant` share self-only payroll visibility (same JOIN rules as former self+assistant).

ALTER TABLE public.staff_member_user_access
  DROP CONSTRAINT IF EXISTS staff_member_user_access_role_check;

UPDATE public.staff_member_user_access
SET access_role = 'stylist'
WHERE access_role = 'self';

ALTER TABLE public.staff_member_user_access
  ALTER COLUMN access_role SET DEFAULT 'stylist';

ALTER TABLE public.staff_member_user_access
  ADD CONSTRAINT staff_member_user_access_role_check
  CHECK (
    access_role = ANY (
      ARRAY['stylist'::text, 'assistant'::text, 'manager'::text, 'admin'::text]
    )
  );

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
    w.location_name
   FROM v_admin_payroll_summary_weekly w
     JOIN staff_member_user_access a ON a.is_active = true
       AND (
         (a.access_role = ANY (ARRAY['stylist'::text, 'assistant'::text])
           AND a.staff_member_id = w.derived_staff_paid_id)
         OR a.access_role = ANY (ARRAY['manager'::text, 'admin'::text])
       )
  WHERE w.derived_staff_paid_id IS NOT NULL
    AND COALESCE(lower(TRIM(BOTH FROM w.derived_staff_paid_display_name)), ''::text) <> 'internal'::text
    AND w.has_unconfigured_paid_staff_rows = false;

CREATE OR REPLACE VIEW public.v_stylist_commission_lines_access_scoped AS
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
    l.customer_name,
    l.product_service_name,
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
    l.stylist_visible_note,
    a.access_role
   FROM v_stylist_commission_lines_secure l
     JOIN staff_member_user_access a ON a.is_active = true
       AND (
         (a.access_role = ANY (ARRAY['stylist'::text, 'assistant'::text])
           AND a.staff_member_id = l.derived_staff_paid_id)
         OR a.access_role = ANY (ARRAY['manager'::text, 'admin'::text])
       );

CREATE OR REPLACE VIEW public.v_stylist_commission_summary_access_scoped AS
 SELECT a.user_id,
    s.month_start,
    s.location_id,
    s.derived_staff_paid_id,
    s.derived_staff_paid_display_name,
    s.derived_staff_paid_full_name,
    s.line_count,
    s.payable_line_count,
    s.expected_no_commission_line_count,
    s.zero_value_line_count,
    s.total_sales_ex_gst,
    s.total_actual_commission_ex_gst,
    s.total_assistant_commission_ex_gst,
    a.access_role
   FROM v_stylist_commission_summary_self_service s
     JOIN staff_member_user_access a ON a.is_active = true
       AND (
         (a.access_role = ANY (ARRAY['stylist'::text, 'assistant'::text])
           AND a.staff_member_id = s.derived_staff_paid_id)
         OR a.access_role = ANY (ARRAY['manager'::text, 'admin'::text])
       );
