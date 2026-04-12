import { useQuery } from '@tanstack/react-query'

import { rpcGetAdminPayrollLinesWeekly } from '@/lib/supabaseRpc'

/** Admin line detail for one pay week. */
export function useAdminPayrollLinesWeekly(payWeekStart: string | undefined) {
  return useQuery({
    queryKey: ['admin-payroll-lines-weekly', payWeekStart] as const,
    queryFn: () => rpcGetAdminPayrollLinesWeekly(payWeekStart!),
    enabled: Boolean(payWeekStart),
  })
}
