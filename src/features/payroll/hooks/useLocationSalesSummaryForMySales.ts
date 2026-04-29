import { useQuery } from '@tanstack/react-query'

import { rpcGetLocationSalesSummaryForMySales } from '@/lib/supabaseRpc'

const QUERY_KEY = ['location-sales-summary-my-sales'] as const

/**
 * Location-level sales totals for My Sales KPI cards (all staff, same basis
 * as Sales Summary). Table/commission continue to use
 * {@link useMyWeeklyCommissionSummary}.
 */
export function useLocationSalesSummaryForMySales() {
  return useQuery({
    queryKey: QUERY_KEY,
    queryFn: rpcGetLocationSalesSummaryForMySales,
  })
}
