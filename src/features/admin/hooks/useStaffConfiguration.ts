import { useQuery } from '@tanstack/react-query'

import type { StaffMemberRow } from '@/features/admin/types/staffConfiguration'
import {
  fetchRemunerationPlanOptions,
  fetchStaffMembers,
  type RemunerationPlanOption,
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
  planOptions: RemunerationPlanOption[]
  locations: ImportLocationRow[]
  salesImportMetadata: StaffSalesImportMetadataRow[]
}

export function useStaffConfiguration() {
  return useQuery({
    queryKey: ['staff-configuration'],
    queryFn: async (): Promise<StaffConfigurationBundle> => {
      const [staff, planOptions, locations, salesImportMetadata] = await Promise.all([
        fetchStaffMembers(),
        fetchRemunerationPlanOptions(),
        rpcListActiveLocationsForImport(),
        rpcListStaffSalesImportMetadata(),
      ])
      const byId = new Map(planOptions.map((plan) => [plan.id, plan.plan_name]))
      return {
        staff: staff.map((row) => ({ ...row, remuneration_plan: row.remuneration_plan_id ? byId.get(row.remuneration_plan_id) ?? row.remuneration_plan : row.remuneration_plan })),
        planNames: planOptions.map((plan) => plan.plan_name), planOptions, locations, salesImportMetadata,
      }
    },
  })
}
