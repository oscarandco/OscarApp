import { useQuery } from '@tanstack/react-query'

import {
  useAccessProfile,
  useHasElevatedAccess,
} from '@/features/access/accessContext'
import {
  rpcGetKpiSnapshotLive,
  type KpiSnapshotScope,
} from '@/features/kpi/data/kpiApi'

/**
 * Live KPI snapshot for the current month, scoped by role:
 *   - elevated (manager / admin) → business scope
 *   - non-elevated (stylist / assistant) → own staff scope
 *
 * We must pick the scope client-side because `private.kpi_resolve_scope`
 * rejects (SQLSTATE 42501) any non-`'staff'` request from a
 * non-elevated caller rather than silently collapsing it. This keeps
 * the frontend in lockstep with the backend access rules and matches
 * how the rest of the app decides "own" vs "all" data access.
 *
 * The query waits until the access profile is resolved (`enabled`)
 * so we don't send an initial `'business'` request while the role is
 * still loading. The resolved scope is part of the query key so
 * cached rows never cross role boundaries.
 */
export function useKpiSnapshot() {
  const { accessState } = useAccessProfile()
  const elevated = useHasElevatedAccess()
  const scope: KpiSnapshotScope = elevated ? 'business' : 'staff'

  return useQuery({
    queryKey: ['kpi-snapshot-live', 'current-month', scope] as const,
    queryFn: () => rpcGetKpiSnapshotLive(scope),
    enabled: accessState === 'ready',
  })
}
