import { useQuery } from '@tanstack/react-query'

import { rpcGetMyCommissionSummaryWeekly } from '@/lib/supabaseRpc'

const QUERY_KEY = ['my-commission-summary-weekly'] as const

/** Stylist weekly summary dashboard — RPC only, stable cache key. */
export function useMyWeeklyCommissionSummary() {
  return useQuery({
    queryKey: QUERY_KEY,
    queryFn: rpcGetMyCommissionSummaryWeekly,
  })
}
