import { useQuery } from '@tanstack/react-query'

import { useAccessProfile } from '@/features/access/accessContext'
import { rpcGetStaffFteForKpiDisplay } from '@/lib/supabaseRpc'

type UseStaffFteForKpiDisplayArgs = {
  /** Selected staff member id (KPI staff scope). */
  staffMemberId: string | null
  enabled?: boolean
}

/**
 * FTE for the staff member currently selected on the KPI dashboard
 * (`get_staff_fte_for_kpi_display`). Used only for admin/manager
 * individual-staff view so volume KPI cards match that member's self
 * view normalisation (`KpiCard` + `NORMALISABLE_KPI_CODES`).
 */
export function useStaffFteForKpiDisplay(args: UseStaffFteForKpiDisplayArgs) {
  const { accessState } = useAccessProfile()
  const { staffMemberId, enabled = true } = args
  const id = typeof staffMemberId === 'string' ? staffMemberId.trim() : ''

  return useQuery({
    queryKey: ['get-staff-fte-for-kpi-display', id] as const,
    queryFn: () => rpcGetStaffFteForKpiDisplay(id),
    enabled: accessState === 'ready' && enabled && id.length > 0,
    staleTime: 5 * 60 * 1000,
  })
}
