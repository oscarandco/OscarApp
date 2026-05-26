/**
 * Contractor Invoices + Business Settings RPC wrappers.
 *
 * All access control happens server-side inside the SECURITY DEFINER RPCs
 * (see supabase/migrations/20260825120100..20260825120400). Frontend gates
 * UI/route visibility via the role_page_permissions matrix, but the
 * authoritative checks live in the DB.
 */
import type { PostgrestError } from '@supabase/supabase-js'

import type { BusinessSettingsRow } from '@/features/admin/types/businessSettings'
import type {
  ContractorInvoiceBatchRow,
  ContractorInvoicePayWeekRow,
  ContractorInvoicePreviewLineRow,
  ContractorInvoiceSnapshot,
  ContractorVoidedInvoiceRow,
} from '@/features/admin/types/contractorInvoice'
import { requireSupabaseClient } from '@/lib/supabase'

function toError(op: string, err: PostgrestError): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

function asRows<T>(data: T | T[] | null): T[] {
  if (data == null) return []
  return Array.isArray(data) ? data : [data]
}

function firstRow<T>(data: T | T[] | null): T | null {
  if (data == null) return null
  return Array.isArray(data) ? (data[0] ?? null) : data
}

// ---------------------------------------------------------------------------
// Business Settings
// ---------------------------------------------------------------------------

export async function rpcGetBusinessSettings(): Promise<BusinessSettingsRow | null> {
  const { data, error } = await requireSupabaseClient().rpc('get_business_settings')
  if (error) throw toError('get_business_settings', error)
  return firstRow(data as BusinessSettingsRow | BusinessSettingsRow[] | null)
}

export async function rpcUpdateBusinessSettings(args: {
  legal_business_name: string
  trading_name: string | null
  street_address: string
  suburb: string
  city_postcode: string
  email: string | null
  phone: string | null
  nzbn: string | null
  gst_number: string | null
}): Promise<BusinessSettingsRow> {
  const { data, error } = await requireSupabaseClient().rpc('update_business_settings', {
    p_legal_business_name: args.legal_business_name,
    p_trading_name: args.trading_name,
    p_street_address: args.street_address,
    p_suburb: args.suburb,
    p_city_postcode: args.city_postcode,
    p_email: args.email,
    p_phone: args.phone,
    p_nzbn: args.nzbn,
    p_gst_number: args.gst_number,
  })
  if (error) throw toError('update_business_settings', error)
  return data as BusinessSettingsRow
}

// ---------------------------------------------------------------------------
// Contractor Invoices
// ---------------------------------------------------------------------------

export async function rpcListContractorInvoicePayWeeks(): Promise<
  ContractorInvoicePayWeekRow[]
> {
  const { data, error } = await requireSupabaseClient().rpc(
    'list_contractor_invoice_pay_weeks',
  )
  if (error) throw toError('list_contractor_invoice_pay_weeks', error)
  return asRows(data as ContractorInvoicePayWeekRow[])
}

export async function rpcGetContractorInvoiceBatch(args: {
  payWeekStart: string
  includeZeroContractors: boolean
}): Promise<ContractorInvoiceBatchRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_contractor_invoice_batch',
    {
      p_pay_week_start: args.payWeekStart,
      p_include_zero_contractors: args.includeZeroContractors,
    },
  )
  if (error) throw toError('get_contractor_invoice_batch', error)
  return asRows(data as ContractorInvoiceBatchRow[])
}

export async function rpcGetContractorInvoicePreview(args: {
  payWeekStart: string
  staffMemberId: string
}): Promise<ContractorInvoicePreviewLineRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_contractor_invoice_preview',
    {
      p_pay_week_start: args.payWeekStart,
      p_staff_member_id: args.staffMemberId,
    },
  )
  if (error) throw toError('get_contractor_invoice_preview', error)
  return asRows(data as ContractorInvoicePreviewLineRow[])
}

export type CreateContractorInvoiceResult = {
  id: string
  invoice_number: string
  revision_number: number
  subtotal_ex_gst: number
  gst_amount: number
  total_inc_gst: number
  line_count: number
}

export async function rpcCreateContractorInvoice(args: {
  payWeekStart: string
  staffMemberId: string
  internalNote: string | null
}): Promise<CreateContractorInvoiceResult> {
  const { data, error } = await requireSupabaseClient().rpc(
    'create_contractor_invoice',
    {
      p_pay_week_start: args.payWeekStart,
      p_staff_member_id: args.staffMemberId,
      p_internal_note: args.internalNote,
    },
  )
  if (error) throw toError('create_contractor_invoice', error)
  return data as CreateContractorInvoiceResult
}

export async function rpcVoidContractorInvoice(args: {
  invoiceId: string
  voidReason: string
}): Promise<void> {
  const { error } = await requireSupabaseClient().rpc('void_contractor_invoice', {
    p_invoice_id: args.invoiceId,
    p_void_reason: args.voidReason,
  })
  if (error) throw toError('void_contractor_invoice', error)
}

export async function rpcReplaceContractorInvoice(args: {
  invoiceId: string
  voidReason: string
  internalNote: string | null
}): Promise<CreateContractorInvoiceResult> {
  const { data, error } = await requireSupabaseClient().rpc(
    'replace_contractor_invoice',
    {
      p_invoice_id: args.invoiceId,
      p_void_reason: args.voidReason,
      p_internal_note: args.internalNote,
    },
  )
  if (error) throw toError('replace_contractor_invoice', error)
  return data as CreateContractorInvoiceResult
}

export async function rpcGetContractorInvoice(
  invoiceId: string,
): Promise<ContractorInvoiceSnapshot> {
  const { data, error } = await requireSupabaseClient().rpc('get_contractor_invoice', {
    p_invoice_id: invoiceId,
  })
  if (error) throw toError('get_contractor_invoice', error)
  return data as ContractorInvoiceSnapshot
}

export async function rpcListContractorVoidedInvoicesForWeek(
  payWeekStart: string,
): Promise<ContractorVoidedInvoiceRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'list_contractor_voided_invoices_for_week',
    { p_pay_week_start: payWeekStart },
  )
  if (error) throw toError('list_contractor_voided_invoices_for_week', error)
  return asRows(data as ContractorVoidedInvoiceRow[])
}
