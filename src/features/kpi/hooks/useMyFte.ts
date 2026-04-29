import { useQuery } from '@tanstack/react-query'

import { useAccessProfile } from '@/features/access/accessContext'
import { rpcGetMyFte } from '@/lib/supabaseRpc'

type UseMyFteArgs = {
  /**
   * Caller-controlled gate. The KPI dashboard uses this for stylist /
   * assistant self view only; admin/manager staff-on-member view uses
   * `useStaffFteForKpiDisplay` instead.
   */
  enabled?: boolean
}

/**
 * Fetches the logged-in user's FTE via `public.get_my_fte()`. Returns
 * `number | null` — null means "no mapping or no fte recorded", in
 * which case the KPI cards should render unchanged (no normalisation).
 *
 * Cached per auth user (the RPC is effectively keyed to `auth.uid()`
 * server-side, so the user id alone is enough for invalidation). The
 * hook piggybacks on the existing access-profile readiness gate so we
 * don't race the bootstrap query.
 *
 * Admin/manager viewing another staff member's KPIs should use
 * `useStaffFteForKpiDisplay` instead.
 */
export function useMyFte(args: UseMyFteArgs = {}) {
  const { accessState, normalized } = useAccessProfile()
  const { enabled = true } = args

  return useQuery({
    queryKey: ['get-my-fte', normalized?.userId ?? null] as const,
    queryFn: rpcGetMyFte,
    enabled: accessState === 'ready' && enabled,
    staleTime: 5 * 60 * 1000,
  })
}
