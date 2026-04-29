import { useQuery } from '@tanstack/react-query'

import { useAccessProfile } from '@/features/access/accessContext'
import {
  rpcGetKpiStylistComparisonsLive,
  type KpiStylistComparisonRow,
  type KpiStylistComparisonsArgs,
} from '@/features/kpi/data/kpiApi'

export type KpiStylistComparisonsQueryPayload = {
  rows: KpiStylistComparisonRow[]
  /** True when the RPC failed — UI can show a soft message without breaking the page. */
  unavailable: boolean
}

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
    queryFn: async (): Promise<KpiStylistComparisonsQueryPayload> => {
      try {
        const rows = await rpcGetKpiStylistComparisonsLive({
          periodStart,
          scope,
          locationId,
          staffMemberId,
        })
        return { rows, unavailable: false }
      } catch {
        return { rows: [], unavailable: true }
      }
    },
    enabled: accessState === 'ready' && enabled,
    retry: false,
  })
}
