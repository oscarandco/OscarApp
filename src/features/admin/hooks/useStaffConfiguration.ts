import { useQuery } from '@tanstack/react-query'

import type { StaffMemberRow } from '@/features/admin/types/staffConfiguration'
import {
  fetchRemunerationPlanNames,
  fetchStaffMembers,
} from '@/lib/staffMembersApi'

export type StaffConfigurationBundle = {
  staff: StaffMemberRow[]
  planNames: string[]
}

export function useStaffConfiguration() {
  return useQuery({
    queryKey: ['staff-configuration'],
    queryFn: async (): Promise<StaffConfigurationBundle> => {
      const [staff, planNames] = await Promise.all([
        fetchStaffMembers(),
        fetchRemunerationPlanNames(),
      ])
      return { staff, planNames }
    },
  })
}
