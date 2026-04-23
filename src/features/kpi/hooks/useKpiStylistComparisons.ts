import { useQuery } from '@tanstack/react-query'

import { useAccessProfile } from '@/features/access/accessContext'
import {
  rpcGetKpiStylistComparisonsLive,
  type KpiStylistComparisonsArgs,
} from '@/features/kpi/data/kpiApi'

type UseKpiStylistComparisonsArgs = KpiStylistComparisonsArgs & {
  /**
   * Caller-controlled gate. The page only fires this query for the
   * staff/self view and only once the snapshot params are ready —
   * mirroring the gating used by `useKpiSnapshot`.
   */
  enabled?: boolean
}

/**
 * Live stylist comparison set for an explicit `(periodStart, staff id)`
 * tuple. The backend RPC returns zero rows for any scope other than
 * `'staff'`, but we still gate at the call site to avoid wasted
 * round-trips on business / location views.
 */
export function useKpiStylistComparisons(args: UseKpiStylistComparisonsArgs) {
  const { accessState } = useAccessProfile()
  const { periodStart, scope, locationId, staffMemberId, enabled = true } = args

  return useQuery({
    queryKey: [
      'kpi-stylist-comparisons-live',
      periodStart,
      scope,
      locationId,
      staffMemberId,
    ] as const,
    queryFn: () =>
      rpcGetKpiStylistComparisonsLive({
        periodStart,
        scope,
        locationId,
        staffMemberId,
      }),
    enabled: accessState === 'ready' && enabled,
  })
}
