import { useQuery } from '@tanstack/react-query'

import { rpcSearchAuthUsers, rpcSearchStaffMembers } from '@/lib/supabaseRpc'

export function useStaffMemberSearch(debouncedQuery: string, enabled: boolean) {
  return useQuery({
    queryKey: ['search-staff-members', debouncedQuery],
    queryFn: () =>
      rpcSearchStaffMembers(
        debouncedQuery.trim() === '' ? null : debouncedQuery.trim(),
      ),
    enabled,
  })
}

export function useAuthUserSearch(debouncedQuery: string, enabled: boolean) {
  return useQuery({
    queryKey: ['search-auth-users', debouncedQuery],
    queryFn: () =>
      rpcSearchAuthUsers(
        debouncedQuery.trim() === '' ? null : debouncedQuery.trim(),
      ),
    enabled,
  })
}
