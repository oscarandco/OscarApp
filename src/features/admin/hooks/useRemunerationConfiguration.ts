import { useQuery } from '@tanstack/react-query'

import {
  fetchRemunerationPlansWithRates,
  fetchRemunerationStaffCounts,
  type PlanStaffCountRow,
} from '@/lib/remunerationPlansApi'
import type { RemunerationPlanWithRates } from '@/features/admin/types/remuneration'

export type RemunerationConfigurationBundle = {
  plans: RemunerationPlanWithRates[]
  staffCounts: PlanStaffCountRow[]
}

export function useRemunerationConfiguration() {
  return useQuery({
    queryKey: ['remuneration-configuration'],
    queryFn: async (): Promise<RemunerationConfigurationBundle> => {
      const [plans, staffCounts] = await Promise.all([
        fetchRemunerationPlansWithRates(),
        fetchRemunerationStaffCounts(),
      ])
      return { plans, staffCounts }
    },
  })
}

export function staffCountForPlan(
  plan: { plan_name: string },
  staffCounts: PlanStaffCountRow[],
): number {
  const key = plan.plan_name.trim().toLowerCase()
  const row = staffCounts.find((c) => c.plan_key === key)
  return row?.staff_count ?? 0
}
