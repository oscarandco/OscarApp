import { useQuery } from '@tanstack/react-query'

import type { StaffMemberRow } from '@/features/admin/types/staffConfiguration'
import {
  fetchRemunerationPlanNames,
  fetchStaffMembers,
} from '@/lib/staffMembersApi'
import {
  rpcListActiveLocationsForImport,
  rpcListStaffSalesImportMetadata,
  type ImportLocationRow,
  type StaffSalesImportMetadataRow,
} from '@/lib/supabaseRpc'

export type StaffConfigurationBundle = {
  staff: StaffMemberRow[]
  planNames: string[]
  locations: ImportLocationRow[]
  salesImportMetadata: StaffSalesImportMetadataRow[]
}

export function useStaffConfiguration() {
  return useQuery({
    queryKey: ['staff-configuration'],
    queryFn: async (): Promise<StaffConfigurationBundle> => {
      const [staff, planNames, locations, salesImportMetadata] = await Promise.all([
        fetchStaffMembers(),
        fetchRemunerationPlanNames(),
        rpcListActiveLocationsForImport(),
        rpcListStaffSalesImportMetadata(),
      ])
      return { staff, planNames, locations, salesImportMetadata }
    },
  })
}
