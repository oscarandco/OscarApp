import { useQuery } from '@tanstack/react-query'

import { rpcGetAdminAccessMappings } from '@/lib/supabaseRpc'

export function useAdminAccessMappings() {
  return useQuery({
    queryKey: ['admin-access-mappings'],
    queryFn: () => rpcGetAdminAccessMappings(),
  })
}
