export type InvoiceMoney = number | string | null
export type InvoiceAppliedRate = { type: string | null; rate: InvoiceMoney }
export type InvoiceCalculationLine = {
  id: string; sale_date: string; sale_datetime: string | null; customer_name: string | null
  product_service_name: string; product_type_actual: string | null; price_ex_gst: InvoiceMoney
  owner_name: string; worker_name: string; eligible: boolean
  product_cost_ex_gst: InvoiceMoney; commissionable_ex_gst: InvoiceMoney
  commission_rate: InvoiceMoney; contractor_fee_ex_gst: InvoiceMoney
}
export type InvoiceCalculationDetail = {
  calculation_version: 2; lines: InvoiceCalculationLine[]
  customer_total_ex_gst: InvoiceMoney; eligible_sales_ex_gst: InvoiceMoney
  product_cost_ex_gst: InvoiceMoney; commissionable_ex_gst: InvoiceMoney; contractor_fee_ex_gst: InvoiceMoney
}
export type InvoiceCalculationSnapshot = {
  calculation_version: 2; product_cost_ex_gst: InvoiceMoney; commissionable_ex_gst: InvoiceMoney
  applied_rates: InvoiceAppliedRate[]; detail: InvoiceCalculationDetail
}

export function readInvoiceCalculationSnapshot(payload: unknown): InvoiceCalculationSnapshot | null {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return null
  const p = payload as Record<string, unknown>
  if (p.calculation_version !== 2 || p.product_cost_ex_gst == null || p.commissionable_ex_gst == null || !Number.isFinite(Number(p.product_cost_ex_gst)) || !Number.isFinite(Number(p.commissionable_ex_gst))) return null
  const detail = p.detail as Record<string, unknown> | null
  if (!detail || detail.calculation_version !== 2 || !Array.isArray(detail.lines) || !Array.isArray(p.applied_rates)) return null
  return p as unknown as InvoiceCalculationSnapshot
}

export function invoiceRateLabel(value: InvoiceMoney): string {
  return value == null ? 'Excluded' : `${(Number(value) * 100).toLocaleString('en-NZ', { maximumFractionDigits: 2 })}%`
}

export function invoiceRateSummary(rates: InvoiceAppliedRate[]): string {
  const labels = rates.filter(r => r.rate != null).map(r => `${r.type || 'Unclassified'}: ${invoiceRateLabel(r.rate)}`)
  return [...new Set(labels)].sort().join(' · ')
}
