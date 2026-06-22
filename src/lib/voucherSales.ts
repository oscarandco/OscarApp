import type { VoucherSalesByLocationRow } from '@/features/payroll/types'

function parseMoney(value: number | string | null | undefined): number | null {
  if (value == null || value === '') return null
  const n = typeof value === 'number' ? value : Number(value)
  return Number.isFinite(n) ? n : null
}

/**
 * Sum voucher sales ex GST from `get_voucher_sales_ex_gst_by_location_for_date_range`
 * rows. When `locationId` is set, only that location is included.
 */
export function sumVoucherSalesExGstFromLocationRows(
  rows: VoucherSalesByLocationRow[],
  locationId?: string,
): number {
  const wantLocation = locationId?.trim() ?? ''
  let total = 0
  for (const row of rows) {
    const lid = String(row.location_id ?? '').trim()
    if (wantLocation !== '' && lid !== wantLocation) continue
    const amount = parseMoney(row.voucher_sales_ex_gst)
    if (amount != null) total += amount
  }
  return Math.round(total * 100) / 100
}
