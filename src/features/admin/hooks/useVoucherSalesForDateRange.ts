import { useQuery } from '@tanstack/react-query'

import type { VoucherSalesByLocationRow } from '@/features/payroll/types'
import { rpcGetVoucherSalesExGstByLocationForDateRange } from '@/lib/supabaseRpc'

const QUERY_KEY = 'voucher-sales-by-location' as const
const STALE_MS = 5 * 60 * 1000

/**
 * Voucher sales ex GST by location for the Sales Summary date range.
 * Source: SalesDailySheets-backed `sales_transactions` (not payroll lines).
 */
export function useVoucherSalesForDateRange(
  startDate: string,
  endDate: string,
) {
  const from = String(startDate ?? '').trim()
  const to = String(endDate ?? '').trim()

  return useQuery<VoucherSalesByLocationRow[]>({
    queryKey: [QUERY_KEY, from, to] as const,
    queryFn: () => rpcGetVoucherSalesExGstByLocationForDateRange(from, to),
    enabled: from !== '' && to !== '',
    staleTime: STALE_MS,
  })
}
