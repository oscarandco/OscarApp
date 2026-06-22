import { useQuery } from '@tanstack/react-query'

import type { VoucherSalesDetailRow } from '@/features/payroll/types'
import { rpcGetVoucherSalesDetailForDateRange } from '@/lib/supabaseRpc'

const QUERY_KEY = 'voucher-sales-detail' as const
const STALE_MS = 5 * 60 * 1000

/**
 * Voucher sale line detail for Sales Summary disclosure modal.
 * Fetches only when `enabled` is true (modal open).
 */
export function useVoucherSalesDetailForDateRange(
  startDate: string,
  endDate: string,
  locationId: string | null,
  enabled: boolean,
) {
  const from = String(startDate ?? '').trim()
  const to = String(endDate ?? '').trim()
  const loc = locationId != null ? String(locationId).trim() : ''

  return useQuery<VoucherSalesDetailRow[]>({
    queryKey: [QUERY_KEY, from, to, loc || null] as const,
    queryFn: () =>
      rpcGetVoucherSalesDetailForDateRange(from, to, loc !== '' ? loc : null),
    enabled: enabled && from !== '' && to !== '',
    staleTime: STALE_MS,
  })
}
