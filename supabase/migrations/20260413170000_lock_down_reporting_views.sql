begin;

-- Revoke direct public/app access from sensitive reporting views
revoke all on table public.v_admin_payroll_lines from anon, authenticated;
revoke all on table public.v_admin_payroll_summary from anon, authenticated;
revoke all on table public.v_admin_payroll_summary_by_location from anon, authenticated;
revoke all on table public.v_admin_payroll_summary_by_stylist from anon, authenticated;
revoke all on table public.v_commission_calculations_core from anon, authenticated;
revoke all on table public.v_commission_calculations_qa from anon, authenticated;
revoke all on table public.v_sales_transactions_enriched from anon, authenticated;
revoke all on table public.v_sales_transactions_powerbi_parity from anon, authenticated;
revoke all on table public.v_stylist_commission_lines_access_scoped from anon, authenticated;
revoke all on table public.v_stylist_commission_lines_final from anon, authenticated;
revoke all on table public.v_stylist_commission_lines_secure from anon, authenticated;
revoke all on table public.v_stylist_commission_summary_access_scoped from anon, authenticated;
revoke all on table public.v_stylist_commission_summary_final from anon, authenticated;
revoke all on table public.v_stylist_commission_summary_secure from anon, authenticated;
revoke all on table public.v_stylist_commission_summary_self_service from anon, authenticated;

-- Keep backend/server access
grant all on table public.v_admin_payroll_lines to service_role;
grant all on table public.v_admin_payroll_summary to service_role;
grant all on table public.v_admin_payroll_summary_by_location to service_role;
grant all on table public.v_admin_payroll_summary_by_stylist to service_role;
grant all on table public.v_commission_calculations_core to service_role;
grant all on table public.v_commission_calculations_qa to service_role;
grant all on table public.v_sales_transactions_enriched to service_role;
grant all on table public.v_sales_transactions_powerbi_parity to service_role;
grant all on table public.v_stylist_commission_lines_access_scoped to service_role;
grant all on table public.v_stylist_commission_lines_final to service_role;
grant all on table public.v_stylist_commission_lines_secure to service_role;
grant all on table public.v_stylist_commission_summary_access_scoped to service_role;
grant all on table public.v_stylist_commission_summary_final to service_role;
grant all on table public.v_stylist_commission_summary_secure to service_role;
grant all on table public.v_stylist_commission_summary_self_service to service_role;

commit;