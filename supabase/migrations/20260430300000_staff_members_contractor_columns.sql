-- Contractor details for staff when employment_type is Contractor (Staff Configuration).

ALTER TABLE public.staff_members
  ADD COLUMN IF NOT EXISTS contractor_company_name text,
  ADD COLUMN IF NOT EXISTS contractor_gst_registered boolean,
  ADD COLUMN IF NOT EXISTS contractor_ird_number text,
  ADD COLUMN IF NOT EXISTS contractor_street_address text,
  ADD COLUMN IF NOT EXISTS contractor_suburb text,
  ADD COLUMN IF NOT EXISTS contractor_city_postcode text;

COMMENT ON COLUMN public.staff_members.contractor_company_name IS 'Contractor company (when employment_type is Contractor).';
COMMENT ON COLUMN public.staff_members.contractor_gst_registered IS 'GST registration flag for contractor.';
COMMENT ON COLUMN public.staff_members.contractor_ird_number IS 'IRD number for contractor.';
COMMENT ON COLUMN public.staff_members.contractor_street_address IS 'Contractor street address.';
COMMENT ON COLUMN public.staff_members.contractor_suburb IS 'Contractor suburb.';
COMMENT ON COLUMN public.staff_members.contractor_city_postcode IS 'Contractor city and postcode (single field).';
