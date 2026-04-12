import { useQuery } from '@tanstack/react-query'

import { rpcGetAdminPayrollSummaryWeekly } from '@/lib/supabaseRpc'

const QUERY_KEY = ['admin-payroll-summary-weekly'] as const

/** Admin weekly summary — server enforces permissions. */
export function useAdminPayrollSummaryWeekly() {
  return useQuery({
    queryKey: QUERY_KEY,
    queryFn: rpcGetAdminPayrollSummaryWeekly,
  })
}
