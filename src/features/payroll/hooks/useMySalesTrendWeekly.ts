import { useQuery } from '@tanstack/react-query'

import { rpcGetMySalesTrendWeekly } from '@/lib/supabaseRpc'

const QUERY_KEY = ['my-sales-trend-weekly'] as const

/**
 * My Sales personal Staff Trends data for the logged-in staff member.
 * RPC only, stable cache key. Returns one row per pay week with effective
 * role / remuneration plan and assistant commission contributor breakdown.
 */
export function useMySalesTrendWeekly() {
  return useQuery({
    queryKey: QUERY_KEY,
    queryFn: rpcGetMySalesTrendWeekly,
  })
}
