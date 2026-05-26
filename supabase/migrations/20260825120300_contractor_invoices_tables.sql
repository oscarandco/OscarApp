-- Contractor Invoices (buyer-created tax invoices for contractor staff).
-- Schema only. RPCs that read/write these tables ship in 20260825120400.
--
-- Design notes:
--   * One active ("created") invoice per contractor per pay week. Voided
--     invoices remain forever for audit. A replacement creates a new row
--     (revision_number++) and links via replaces_invoice_id / replaced_by_invoice_id.
--   * Header table snapshots ALL buyer + contractor profile fields at create
--     time. Snapshot is what the PDF renders from. Source values can change
--     later without touching saved invoices.
--   * Lines table snapshots one row per Kitomba/client invoice. Amounts are
--     copied verbatim from Weekly Payroll (we do not recompute commission).

-- ---------------------------------------------------------------------------
-- contractor_invoices (header)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.contractor_invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  -- Numbering
  invoice_number text NOT NULL,
  base_invoice_number text NOT NULL,
  revision_number integer NOT NULL DEFAULT 0,
  -- Status
  status text NOT NULL CHECK (status IN ('created','voided')),
  -- Pay week
  pay_week_start date NOT NULL,
  pay_week_end date NOT NULL,
  invoice_date date NOT NULL,
  -- Contractor identity
  contractor_staff_member_id uuid NOT NULL REFERENCES public.staff_members(id),
  -- Totals
  subtotal_ex_gst numeric NOT NULL CHECK (subtotal_ex_gst > 0),
  gst_rate numeric NOT NULL DEFAULT 0.15,
  gst_amount numeric NOT NULL CHECK (gst_amount >= 0),
  total_inc_gst numeric NOT NULL CHECK (total_inc_gst > 0),
  source_generated_at timestamptz NOT NULL,
  internal_note text NULL,
  -- Buyer snapshot
  buyer_legal_business_name text NOT NULL,
  buyer_trading_name text NULL,
  buyer_street_address text NOT NULL,
  buyer_suburb text NOT NULL,
  buyer_city_postcode text NOT NULL,
  buyer_email text NULL,
  buyer_phone text NULL,
  buyer_nzbn text NULL,
  buyer_gst_number text NULL,
  -- Contractor snapshot
  contractor_full_name text NOT NULL,
  contractor_display_name text NULL,
  contractor_invoice_name text NULL,
  contractor_company_name text NULL,
  contractor_invoice_code text NOT NULL,
  contractor_email text NULL,
  contractor_gst_registered boolean NOT NULL,
  contractor_gst_number_display_value text NULL,
  contractor_street_address text NOT NULL,
  contractor_suburb text NOT NULL,
  contractor_city_postcode text NOT NULL,
  contractor_primary_location_id uuid NULL REFERENCES public.locations(id) ON DELETE SET NULL,
  -- Replacement linkage
  replaces_invoice_id uuid NULL REFERENCES public.contractor_invoices(id) ON DELETE SET NULL,
  replaced_by_invoice_id uuid NULL REFERENCES public.contractor_invoices(id) ON DELETE SET NULL,
  -- Void
  voided_at timestamptz NULL,
  voided_by uuid NULL REFERENCES auth.users(id) ON DELETE SET NULL,
  void_reason text NULL,
  -- Audit
  created_by uuid NOT NULL REFERENCES auth.users(id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.contractor_invoices OWNER TO postgres;

COMMENT ON TABLE public.contractor_invoices IS
  'Buyer-created tax invoice headers for contractor staff. Snapshots buyer + contractor profile '
  'and Weekly Payroll totals at creation time. Lines in contractor_invoice_lines.';

-- Indexes for the weekly batch + saved-invoice views.
CREATE INDEX IF NOT EXISTS contractor_invoices_pay_week_idx
  ON public.contractor_invoices (pay_week_start, contractor_staff_member_id);
CREATE INDEX IF NOT EXISTS contractor_invoices_contractor_idx
  ON public.contractor_invoices (contractor_staff_member_id, pay_week_start);
CREATE INDEX IF NOT EXISTS contractor_invoices_status_idx
  ON public.contractor_invoices (status);
CREATE INDEX IF NOT EXISTS contractor_invoices_invoice_number_idx
  ON public.contractor_invoices (invoice_number);

-- One ACTIVE invoice per contractor per pay week. Voided rows are excluded
-- by the partial unique index, so multiple voided revisions can coexist.
CREATE UNIQUE INDEX IF NOT EXISTS contractor_invoices_active_per_contractor_week_uidx
  ON public.contractor_invoices (contractor_staff_member_id, pay_week_start)
  WHERE status = 'created';

-- updated_at trigger
CREATE OR REPLACE FUNCTION public.contractor_invoices_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;

ALTER FUNCTION public.contractor_invoices_set_updated_at() OWNER TO postgres;

DROP TRIGGER IF EXISTS contractor_invoices_set_updated_at ON public.contractor_invoices;
CREATE TRIGGER contractor_invoices_set_updated_at
  BEFORE UPDATE ON public.contractor_invoices
  FOR EACH ROW EXECUTE FUNCTION public.contractor_invoices_set_updated_at();

-- ---------------------------------------------------------------------------
-- contractor_invoice_lines
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.contractor_invoice_lines (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contractor_invoice_id uuid NOT NULL
    REFERENCES public.contractor_invoices(id) ON DELETE CASCADE,
  line_number integer NOT NULL,
  sale_date date NULL,
  source_invoice_number text NOT NULL,
  customer_name text NULL,
  location_id uuid NULL REFERENCES public.locations(id) ON DELETE SET NULL,
  location_name text NULL,
  client_invoice_amount_ex_gst numeric NOT NULL CHECK (client_invoice_amount_ex_gst >= 0),
  commission_percentage numeric NULL,
  contractor_amount_ex_gst numeric NOT NULL CHECK (contractor_amount_ex_gst >= 0),
  source_payload jsonb NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT contractor_invoice_lines_unique_line_no
    UNIQUE (contractor_invoice_id, line_number)
);

ALTER TABLE public.contractor_invoice_lines OWNER TO postgres;

COMMENT ON TABLE public.contractor_invoice_lines IS
  'One row per client (Kitomba) invoice represented in a contractor invoice. '
  'contractor_amount_ex_gst copied directly from Weekly Payroll; never recomputed.';

CREATE INDEX IF NOT EXISTS contractor_invoice_lines_invoice_idx
  ON public.contractor_invoice_lines (contractor_invoice_id, line_number);

-- ---------------------------------------------------------------------------
-- RLS: all reads/writes go through SECURITY DEFINER RPCs.
--      Lock both tables down from authenticated direct access.
-- ---------------------------------------------------------------------------
ALTER TABLE public.contractor_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contractor_invoice_lines ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.contractor_invoices FROM PUBLIC;
REVOKE ALL ON TABLE public.contractor_invoices FROM authenticated;
REVOKE ALL ON TABLE public.contractor_invoice_lines FROM PUBLIC;
REVOKE ALL ON TABLE public.contractor_invoice_lines FROM authenticated;
