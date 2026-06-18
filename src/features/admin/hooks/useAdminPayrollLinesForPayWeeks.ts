import { useMemo } from 'react'
import { useQueries } from '@tanstack/react-query'

import type { AdminPayrollLineRow } from '@/features/admin/types'
import { rpcGetAdminPayrollLinesWeekly } from '@/lib/supabaseRpc'

const STALE_MS = 5 * 60 * 1000

/**
 * Fetch admin payroll lines for multiple pay weeks (parallel queries).
 * Used by Sales Summary voucher disclosure without changing payroll totals.
 */
export function useAdminPayrollLinesForPayWeeks(payWeekStarts: string[]) {
  const weeks = useMemo(() => {
    const set = new Set<string>()
    for (const w of payWeekStarts) {
      const t = String(w ?? '').trim()
      if (t) set.add(t)
    }
    return Array.from(set).sort()
  }, [payWeekStarts])

  const queries = useQueries({
    queries: weeks.map((payWeekStart) => ({
      queryKey: ['admin-payroll-lines-weekly', payWeekStart] as const,
      queryFn: () => rpcGetAdminPayrollLinesWeekly(payWeekStart),
      staleTime: STALE_MS,
    })),
  })

  const isLoading = queries.some((q) => q.isLoading)
  const isError = queries.some((q) => q.isError)

  const data = useMemo((): AdminPayrollLineRow[] => {
    const out: AdminPayrollLineRow[] = []
    for (const q of queries) {
      if (q.data) out.push(...q.data)
    }
    return out
  }, [queries])

  return { weeks, data, isLoading, isError }
}
