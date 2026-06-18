/** Minimal line shape for voucher sales detection and summing. */
export type VoucherSaleLine = {
  product_type_short?: string | null
  product_type_short_derived?: string | null
  commission_product_service?: string | null
  price_ex_gst?: number | string | null
  location_id?: string | null
}

/**
 * Voucher sale rows for Sales Summary disclosure: `product_type_short` or
 * `commission_product_service` equals "Voucher" (case-insensitive).
 */
export function isVoucherSaleRow(line: VoucherSaleLine): boolean {
  const short = String(
    line.product_type_short ?? line.product_type_short_derived ?? '',
  )
    .trim()
    .toLowerCase()
  const commissionProduct = String(line.commission_product_service ?? '')
    .trim()
    .toLowerCase()
  return short === 'voucher' || commissionProduct === 'voucher'
}

function parsePriceExGst(value: number | string | null | undefined): number | null {
  if (value == null || value === '') return null
  const n = typeof value === 'number' ? value : Number(value)
  return Number.isFinite(n) ? n : null
}

/**
 * Sum `price_ex_gst` for voucher rows. When `locationId` is set, only rows
 * for that location are included.
 */
export function sumVoucherSalesExGstFromLines(
  lines: VoucherSaleLine[],
  locationId?: string,
): number {
  const wantLocation = locationId?.trim() ?? ''
  let total = 0
  for (const line of lines) {
    if (!isVoucherSaleRow(line)) continue
    if (wantLocation !== '') {
      const lid = String(line.location_id ?? '').trim()
      if (lid !== wantLocation) continue
    }
    const price = parsePriceExGst(line.price_ex_gst)
    if (price != null) total += price
  }
  return Math.round(total * 100) / 100
}
