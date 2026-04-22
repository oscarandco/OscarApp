import type { PostgrestError } from '@supabase/supabase-js'

import { requireSupabaseClient } from '@/lib/supabase'

/**
 * One row returned by `public.get_kpi_snapshot_live` — the locked
 * 12-column KPI shape shared by every live KPI RPC. Numeric columns
 * may arrive as `number` or `string` depending on the PostgREST
 * encoding, so accept both and normalise at the call site via
 * `Number(...)`.
 */
export type KpiSnapshotRow = {
  kpi_code: string
  scope_type: 'business' | 'location' | 'staff'
  location_id: string | null
  staff_member_id: string | null
  period_start: string
  period_end: string
  mtd_through: string
  is_current_open_month: boolean
  value: number | string | null
  value_numerator: number | string | null
  value_denominator: number | string | null
  source: string | null
}

function toError(op: string, err: PostgrestError): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

/** Scope the frontend asks for — the dispatcher validates it server-side. */
export type KpiSnapshotScope = 'business' | 'staff'

/**
 * Fetch the live KPI snapshot for the caller's current month. The
 * caller-side picks `scope`:
 *   - elevated users (manager / admin) → 'business'
 *   - non-elevated users (stylist / assistant) → 'staff'
 * Passing `'staff'` with a NULL `p_staff_member_id` lets
 * `private.kpi_resolve_scope` resolve the caller's own staff id from
 * `auth.uid()`. `private.kpi_resolve_scope` will raise SQLSTATE 42501
 * if a non-elevated caller asks for business scope, so this mapping
 * must stay in lockstep with `useHasElevatedAccess`.
 */
export async function rpcGetKpiSnapshotLive(
  scope: KpiSnapshotScope,
): Promise<KpiSnapshotRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_kpi_snapshot_live',
    { p_scope: scope },
  )
  if (error) throw toError('get_kpi_snapshot_live', error)
  if (data == null) return []
  return Array.isArray(data)
    ? (data as KpiSnapshotRow[])
    : [data as KpiSnapshotRow]
}
