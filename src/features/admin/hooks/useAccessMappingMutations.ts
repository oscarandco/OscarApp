import { useMutation, useQueryClient } from '@tanstack/react-query'

import {
  rpcCreateAccessMapping,
  rpcUpdateAccessMapping,
} from '@/lib/supabaseRpc'

export function useCreateAccessMappingMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: rpcCreateAccessMapping,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['admin-access-mappings'] })
      void queryClient.invalidateQueries({ queryKey: ['search-auth-users'] })
    },
  })
}

export function useUpdateAccessMappingMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: rpcUpdateAccessMapping,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['admin-access-mappings'] })
    },
  })
}
