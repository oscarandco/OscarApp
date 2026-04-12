import { useQuery } from '@tanstack/react-query'

import { rpcGetMyCommissionLinesWeekly } from '@/lib/supabaseRpc'

/** Line detail for one pay week (`YYYY-MM-DD` matching RPC). */
export function useMyWeeklyCommissionLines(payWeekStart: string | undefined) {
  return useQuery({
    queryKey: ['my-commission-lines-weekly', payWeekStart] as const,
    queryFn: () => rpcGetMyCommissionLinesWeekly(payWeekStart!),
    enabled: Boolean(payWeekStart),
  })
}
