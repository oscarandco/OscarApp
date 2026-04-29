import type { PostgrestError } from '@supabase/supabase-js'
import { useQuery } from '@tanstack/react-query'

import { useAccessProfile } from '@/features/access/accessContext'
import { useAuth } from '@/features/auth/authContext'
import {
  rpcGetKpiStylistComparisonsLive,
  type KpiStylistComparisonRow,
  type KpiStylistComparisonsArgs,
} from '@/features/kpi/data/kpiApi'
import { requireSupabaseClient } from '@/lib/supabase'

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
function logPostgrestRpcFailure(op: string, err: unknown) {
  const pe = err as Partial<PostgrestError> | null
  if (!pe || typeof pe !== 'object') {
    console.warn(`[${op}]`, { code: undefined, message: String(err) })
    return
  }
  console.warn(`[${op}]`, {
    code: pe.code,
    message: pe.message,
    details: pe.details,
    hint: pe.hint,
  })
}

export function useKpiStylistComparisons(args: UseKpiStylistComparisonsArgs) {
  const { accessState } = useAccessProfile()
  const { session, user, loading: authLoading } = useAuth()
  const { periodStart, scope, locationId, staffMemberId, enabled = true } = args

  const sessionReady =
    !authLoading &&
    Boolean(session?.access_token) &&
    Boolean(user?.id)

  const staffKeyReady =
    scope !== 'staff' ||
    (typeof staffMemberId === 'string' &&
      staffMemberId.length > 0)

  const periodReady =
    typeof periodStart === 'string' && periodStart.length >= 8

  return useQuery({
    queryKey: [
      'kpi-stylist-comparisons-live',
      user?.id ?? null,
      periodStart,
      scope,
      locationId,
      staffMemberId,
    ] as const,
    queryFn: async (): Promise<KpiStylistComparisonsQueryPayload> => {
      const client = requireSupabaseClient()
      const { data: sessWrap, error: sessErr } = await client.auth.getSession()
      if (sessErr) {
        console.warn('[get_kpi_stylist_comparisons_live] getSession error', {
          message: sessErr.message,
          name: sessErr.name,
          status: sessErr.status,
        })
        return { rows: [], unavailable: true }
      }
      if (!sessWrap.session?.access_token) {
        console.warn(
          '[get_kpi_stylist_comparisons_live] skipping RPC: no session access_token after getSession()',
        )
        return { rows: [], unavailable: true }
      }

      try {
        const rows = await rpcGetKpiStylistComparisonsLive({
          periodStart,
          scope,
          locationId,
          staffMemberId,
        })
        return { rows, unavailable: false }
      } catch (e) {
        const cause = e instanceof Error ? e.cause : null
        logPostgrestRpcFailure('get_kpi_stylist_comparisons_live', cause ?? e)
        return { rows: [], unavailable: true }
      }
    },
    enabled:
      accessState === 'ready' &&
      sessionReady &&
      periodReady &&
      staffKeyReady &&
      enabled,
    retry: false,
  })
}
