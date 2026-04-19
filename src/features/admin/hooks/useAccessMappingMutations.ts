import { useMutation, useQueryClient } from '@tanstack/react-query'

import {
  rpcCreateAccessMapping,
  rpcUpdateAccessMapping,
} from '@/lib/supabaseRpc'

/**
 * Every access-mapping mutation can change the signed-in user's own
 * access role (e.g. an admin demotes themselves to `assistant` for
 * testing, or activates/deactivates one of their own mappings). The
 * `useAccessProfile` hook is fed by React Query under the
 * `['access-profile', userId]` key and is the single source of truth
 * for sidebar visibility, page-level route guards, and per-page rules
 * like My Sales' role-based filters/cards/columns
 * (`mySalesVisibilityForRole`).
 *
 * Invalidating that key alongside the admin-listing keys ensures the
 * UI reflects the new role immediately — without it, the cached
 * profile keeps serving the previous role until a full page reload.
 */
const ACCESS_PROFILE_KEY = ['access-profile'] as const

export function useCreateAccessMappingMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: rpcCreateAccessMapping,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['admin-access-mappings'] })
      void queryClient.invalidateQueries({ queryKey: ['search-auth-users'] })
      void queryClient.invalidateQueries({ queryKey: ACCESS_PROFILE_KEY })
    },
  })
}

export function useUpdateAccessMappingMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: rpcUpdateAccessMapping,
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['admin-access-mappings'] })
      void queryClient.invalidateQueries({ queryKey: ACCESS_PROFILE_KEY })
    },
  })
}
