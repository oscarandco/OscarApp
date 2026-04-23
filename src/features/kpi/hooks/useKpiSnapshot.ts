import { useQuery } from '@tanstack/react-query'

import { useAccessProfile } from '@/features/access/accessContext'
import {
  rpcGetKpiSnapshotLive,
  type KpiSnapshotArgs,
} from '@/features/kpi/data/kpiApi'

type UseKpiSnapshotArgs = KpiSnapshotArgs & {
  /**
   * Caller-controlled "params are ready to fire" flag. The page owns
   * the gating because only it knows whether the user is elevated
   * (elevated + `scope='staff'` still needs an explicit staff id,
   * non-elevated + `scope='staff'` does not).
   */
  enabled?: boolean
}

/**
 * Live KPI snapshot for an explicit `(periodStart, scope, ids)` tuple.
 * The query waits until the access profile is resolved so we never
 * fire an initial request before the caller's role is known. The
 * scope + ids + period are part of the query key so cached rows
 * never cross boundaries between months or scopes.
 */
export function useKpiSnapshot(args: UseKpiSnapshotArgs) {
  const { accessState } = useAccessProfile()
  const { periodStart, scope, locationId, staffMemberId, enabled = true } = args

  return useQuery({
    queryKey: [
      'kpi-snapshot-live',
      periodStart,
      scope,
      locationId,
      staffMemberId,
    ] as const,
    queryFn: () =>
      rpcGetKpiSnapshotLive({
        periodStart,
        scope,
        locationId,
        staffMemberId,
      }),
    enabled: accessState === 'ready' && enabled,
  })
}
