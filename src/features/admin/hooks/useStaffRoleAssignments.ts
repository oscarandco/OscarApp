import { useQuery } from '@tanstack/react-query'

import type { StaffRoleAssignmentRow } from '@/features/admin/types/staffConfiguration'
import { fetchStaffRoleAssignments } from '@/lib/staffMembersApi'

/**
 * Lists the effective-dated role/pay history for a single staff member.
 * Disabled until a staff member id is supplied. Returns most-recent-first,
 * with `primary_location_name` joined for display by the RPC.
 */
export function useStaffRoleAssignments(staffMemberId: string | null | undefined) {
  return useQuery<StaffRoleAssignmentRow[]>({
    queryKey: ['staff-role-assignments', staffMemberId ?? ''],
    queryFn: () => fetchStaffRoleAssignments(staffMemberId ?? ''),
    enabled: !!staffMemberId,
  })
}
