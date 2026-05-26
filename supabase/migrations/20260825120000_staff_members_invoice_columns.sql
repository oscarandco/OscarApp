-- Contractor invoicing fields for staff_members (Staff Configuration → Contractor block).
-- These are required setup for buyer-created tax invoices generated under
-- /app/admin/contractor-invoices. All nullable; required completeness is enforced
-- by create_contractor_invoice at invoice-creation time, not by the column itself,
-- so existing rows are unaffected.

ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS contractor_email text,
  ADD COLUMN IF NOT EXISTS contractor_invoice_name text,
  ADD COLUMN IF NOT EXISTS contractor_invoice_code text;

COMMENT ON COLUMN public.staff_members.contractor_email IS
  'Contractor billing email shown on the contractor invoice (optional, not sent in MVP).';
COMMENT ON COLUMN public.staff_members.contractor_invoice_name IS
  'Personal/contractor name shown on the invoice when separate from contractor_company_name. '
  'Falls back to staff_members.full_name for display only; invoice creation requires this when '
  'contractor_company_name is not set.';
COMMENT ON COLUMN public.staff_members.contractor_invoice_code IS
  'Short stable code (e.g. ''EF'') used to compose contractor invoice numbers like EF-25-0608. '
  'Required before a contractor invoice can be created.';
