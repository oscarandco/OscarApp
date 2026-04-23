import { useQuery } from '@tanstack/react-query'

import { useAccessProfile } from '@/features/access/accessContext'
import {
  rpcGetKpiDrilldownLive,
  type KpiDrilldownArgs,
} from '@/features/kpi/data/kpiApi'

type UseKpiDrilldownArgs = KpiDrilldownArgs & {
  /**
   * Caller-controlled gate. The dashboard page disables the query for
   * the same "elevated + no id picked yet" cases as `useKpiSnapshot`
   * so we never fire the RPC in states that would raise.
   */
  enabled?: boolean
}

/**
 * Fetch the raw rows behind a single KPI for the currently-selected
 * `(period, scope, ids)`. Waits until the access profile is ready so
 * we never fire before the caller's role is known; the backend
 * silently collapses non-elevated callers to their own staff scope.
 * Keys on `(kpiCode, period, scope, ids)` so a re-selection of a new
 * KPI or a filter change always triggers a fresh fetch.
 */
export function useKpiDrilldown(args: UseKpiDrilldownArgs) {
  const { accessState } = useAccessProfile()
  const {
    kpiCode,
    periodStart,
    scope,
    locationId,
    staffMemberId,
    enabled = true,
  } = args

  return useQuery({
    queryKey: [
      'kpi-drilldown-live',
      kpiCode,
      periodStart,
      scope,
      locationId,
      staffMemberId,
    ] as const,
    queryFn: () =>
      rpcGetKpiDrilldownLive({
        kpiCode,
        periodStart,
        scope,
        locationId,
        staffMemberId,
      }),
    enabled: accessState === 'ready' && enabled && !!kpiCode,
  })
}
