import { useQuery } from '@tanstack/react-query'

import type { StaffMemberRow } from '@/features/admin/types/staffConfiguration'
import {
  fetchRemunerationPlanNames,
  fetchStaffMembers,
} from '@/lib/staffMembersApi'
import { rpcListActiveLocationsForImport, type ImportLocationRow } from '@/lib/supabaseRpc'

export type StaffConfigurationBundle = {
  staff: StaffMemberRow[]
  planNames: string[]
  locations: ImportLocationRow[]
}

export function useStaffConfiguration() {
  return useQuery({
    queryKey: ['staff-configuration'],
    queryFn: async (): Promise<StaffConfigurationBundle> => {
      const [staff, planNames, locations] = await Promise.all([
        fetchStaffMembers(),
        fetchRemunerationPlanNames(),
        rpcListActiveLocationsForImport(),
      ])
      return { staff, planNames, locations }
    },
  })
}
