/**
 * Types for Admin > Contractor Invoices (buyer-created tax invoices).
 *
 * - ContractorInvoiceBatchRow: per-contractor totals for a pay week
 *   (returned by get_contractor_invoice_batch)
 * - ContractorInvoicePreviewLineRow: pre-create preview line
 *   (returned by get_contractor_invoice_preview)
 * - ContractorInvoiceHeader / ContractorInvoiceLine: saved invoice snapshot
 *   (returned by get_contractor_invoice — { header, lines, ... } jsonb)
 */

import type { BusinessSettingsRow } from './businessSettings'

export type ContractorInvoiceBatchRow = {
  staff_member_id: string
  contractor_full_name: string
  contractor_display_name: string | null
  contractor_invoice_name: string | null
  contractor_company_name: string | null
  contractor_invoice_code: string | null
  contractor_email: string | null
  contractor_gst_registered: boolean | null
  contractor_ird_number: string | null
  contractor_street_address: string | null
  contractor_suburb: string | null
  contractor_city_postcode: string | null
  contractor_primary_location_id: string | null
  contractor_primary_location_code: string | null
  contractor_primary_location_name: string | null
  contractor_is_active: boolean
  pay_week_start: string
  pay_week_end: string
  payable_line_count: number
  payable_subtotal_ex_gst: number | string
  payable_gst_amount: number | string
  payable_total_inc_gst: number | string
  /** Comma-separated location codes for the badge column (e.g. 'ORE', 'TAK', 'ORE, TAK'). */
  payable_location_codes: string | null
  active_invoice_id: string | null
  active_invoice_number: string | null
  active_invoice_status: string | null
  active_invoice_revision_number: number | string | null
  active_invoice_total_inc_gst: number | string | null
  active_invoice_created_at: string | null
  setup_missing_fields: string[] | null
}

export type ContractorInvoicePreviewLineRow = {
  staff_member_id: string
  pay_week_start: string
  pay_week_end: string
  source_invoice_number: string
  sale_date: string | null
  customer_name: string | null
  location_id: string | null
  location_name: string | null
  client_invoice_amount_ex_gst: number | string
  contractor_amount_ex_gst: number | string
  commission_percentage: number | string | null
}

export type ContractorInvoiceHeader = {
  id: string
  invoice_number: string
  base_invoice_number: string
  revision_number: number
  status: 'created' | 'voided'
  pay_week_start: string
  pay_week_end: string
  invoice_date: string
  contractor_staff_member_id: string
  subtotal_ex_gst: number | string
  gst_rate: number | string
  gst_amount: number | string
  total_inc_gst: number | string
  source_generated_at: string
  internal_note: string | null
  buyer_legal_business_name: string
  buyer_trading_name: string | null
  buyer_street_address: string
  buyer_suburb: string
  buyer_city_postcode: string
  buyer_email: string | null
  buyer_phone: string | null
  buyer_nzbn: string | null
  buyer_gst_number: string | null
  contractor_full_name: string
  contractor_display_name: string | null
  contractor_invoice_name: string | null
  contractor_company_name: string | null
  contractor_invoice_code: string
  contractor_email: string | null
  contractor_gst_registered: boolean
  contractor_gst_number_display_value: string | null
  contractor_street_address: string
  contractor_suburb: string
  contractor_city_postcode: string
  contractor_primary_location_id: string | null
  replaces_invoice_id: string | null
  replaced_by_invoice_id: string | null
  voided_at: string | null
  voided_by: string | null
  void_reason: string | null
  created_by: string
  created_at: string
  updated_at: string
}

export type ContractorInvoiceLine = {
  id: string
  contractor_invoice_id: string
  line_number: number
  sale_date: string | null
  source_invoice_number: string
  customer_name: string | null
  location_id: string | null
  location_name: string | null
  client_invoice_amount_ex_gst: number | string
  commission_percentage: number | string | null
  contractor_amount_ex_gst: number | string
  source_payload: unknown
  created_at: string
}

export type ContractorInvoiceSnapshot = {
  header: ContractorInvoiceHeader
  lines: ContractorInvoiceLine[]
  replaces_invoice_number: string | null
  replaced_by_invoice_number: string | null
}

export type ContractorInvoicePayWeekRow = {
  pay_week_start: string
  pay_week_end: string
}

/**
 * Compact voided-invoice row returned by `list_contractor_voided_invoices_for_week`.
 * Used by the secondary "Voided invoices for this pay week" table on the
 * Contractor Invoices batch page when the user opts in via the "Show
 * voided invoices" toggle. Distinct from {@link ContractorInvoiceBatchRow}
 * (which is per-contractor and active-only) so the two render paths stay
 * decoupled.
 */
export type ContractorVoidedInvoiceRow = {
  invoice_id: string
  invoice_number: string
  revision_number: number
  staff_member_id: string
  contractor_full_name: string
  contractor_display_name: string | null
  contractor_company_name: string | null
  contractor_is_active: boolean
  contractor_gst_registered: boolean
  contractor_primary_location_code: string | null
  pay_week_start: string
  pay_week_end: string
  subtotal_ex_gst: number | string
  gst_amount: number | string
  total_inc_gst: number | string
  voided_at: string | null
  void_reason: string | null
  created_at: string
  replaced_by_invoice_id: string | null
  replaced_by_invoice_number: string | null
}

// ---------------------------------------------------------------------------
// Pure derivations — used by both batch page and PDF view
// ---------------------------------------------------------------------------

/**
 * Required contractor setup fields per the spec. Returns the list of
 * field names from `staff_members` that are missing for this contractor.
 * Mirrors the server-side check in create_contractor_invoice so the UI
 * can show the same warnings before submit.
 *
 * Person name comes from `staff_members.full_name`, so there is no
 * contractor_invoice_name requirement here (or on the server).
 */
export function contractorInvoiceMissingFields(input: {
  contractor_invoice_code: string | null | undefined
  contractor_gst_registered: boolean | null | undefined
  contractor_street_address: string | null | undefined
  contractor_suburb: string | null | undefined
  contractor_city_postcode: string | null | undefined
  contractor_ird_number: string | null | undefined
}): string[] {
  const missing: string[] = []
  const blank = (s: string | null | undefined) =>
    s == null || String(s).trim() === ''
  if (blank(input.contractor_invoice_code)) missing.push('contractor_invoice_code')
  if (input.contractor_gst_registered == null) missing.push('contractor_gst_registered')
  if (blank(input.contractor_street_address)) missing.push('contractor_street_address')
  if (blank(input.contractor_suburb)) missing.push('contractor_suburb')
  if (blank(input.contractor_city_postcode)) missing.push('contractor_city_postcode')
  if (input.contractor_gst_registered === true && blank(input.contractor_ird_number)) {
    missing.push('contractor_ird_number')
  }
  return missing
}

export function locationCodesArray(value: string | null | undefined): string[] {
  if (!value) return []
  return value
    .split(',')
    .map((s) => s.trim().toUpperCase())
    .filter((s) => s.length > 0)
}

/** Decide the location code badges to render in the batch table. */
export function batchRowLocationBadges(
  row: ContractorInvoiceBatchRow,
): Array<'O' | 'T'> {
  const codes = locationCodesArray(row.payable_location_codes)
  const out: Array<'O' | 'T'> = []
  for (const code of codes) {
    if (code === 'ORE' && !out.includes('O')) out.push('O')
    if (code === 'TAK' && !out.includes('T')) out.push('T')
  }
  if (out.length === 0) {
    const primary = String(row.contractor_primary_location_code ?? '')
      .trim()
      .toUpperCase()
    if (primary === 'ORE') out.push('O')
    if (primary === 'TAK') out.push('T')
  }
  return out
}

/**
 * Render the contractor "name" for the batch / invoice. Person name is
 * always `staff_members.full_name`; falls back to company_name only when
 * full_name is empty (defensive — full_name is required on staff_members).
 */
export function contractorDisplayName(row: {
  contractor_company_name?: string | null
  contractor_full_name: string
}): string {
  const full = String(row.contractor_full_name ?? '').trim()
  if (full !== '') return full
  const c = String(row.contractor_company_name ?? '').trim()
  return c
}

/**
 * Combined "Person - Company" label used by the Contractor Invoices batch
 * table, preview modal header, and create confirmation.
 *
 * Person name comes from `staff_members.full_name` only — no override via
 * contractor_invoice_name. The dash is always rendered so the column shape
 * is stable even when the contractor has no company name (sole traders
 * appear as `Jarod Fisher -`).
 *
 * NOT used by the printed invoice — the printed Supplier block keeps its
 * own "company first, then full name" layout (see ContractorInvoicePrintView).
 */
export function contractorPersonAndCompany(row: {
  contractor_company_name?: string | null
  contractor_full_name: string
}): string {
  const person = String(row.contractor_full_name ?? '').trim()
  const company = String(row.contractor_company_name ?? '').trim()
  return `${person} - ${company}`
}

/** True when the saved invoice has lines from more than one distinct location. */
export function invoiceHasMultipleLocations(
  lines: ContractorInvoiceLine[],
): boolean {
  const set = new Set<string>()
  for (const l of lines) {
    const id = String(l.location_id ?? '').trim()
    if (id !== '') set.add(id)
  }
  return set.size > 1
}

/** Map raw DB field names to user-friendly labels for setup warnings. */
export const CONTRACTOR_FIELD_LABELS: Record<string, string> = {
  contractor_invoice_code: 'Contractor invoice code',
  contractor_gst_registered: 'GST registered (Yes/No)',
  contractor_street_address: 'Street address',
  contractor_suburb: 'Suburb',
  contractor_city_postcode: 'City and postcode',
  contractor_ird_number: 'IRD number (for GST)',
}

export const BUSINESS_SETTINGS_FIELD_LABELS: Partial<Record<keyof BusinessSettingsRow, string>> = {
  legal_business_name: 'Legal business name',
  street_address: 'Street address',
  suburb: 'Suburb',
  city_postcode: 'City and postcode',
}
