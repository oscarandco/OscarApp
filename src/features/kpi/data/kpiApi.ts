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

/** Scope the frontend asks for — the dispatcher validates it server-side. */
export type KpiSnapshotScope = 'business' | 'location' | 'staff'

/**
 * One row returned by `public.get_kpi_drilldown_live`. Intentionally
 * generic so every KPI can share one renderer. `raw_payload` carries
 * the diagnostic context that did not fit into the flat columns.
 */
export type KpiDrilldownRow = {
  kpi_code: string
  row_type: string
  primary_label: string | null
  secondary_label: string | null
  metric_value: number | string | null
  metric_value_2: number | string | null
  event_date: string | null
  location_id: string | null
  staff_member_id: string | null
  raw_payload: Record<string, unknown> | null
}

export type KpiDrilldownArgs = {
  kpiCode: string
  periodStart: string
  scope: KpiSnapshotScope
  locationId: string | null
  staffMemberId: string | null
}

/** Arguments for `rpcGetKpiSnapshotLive`. Matches the RPC params 1:1. */
export type KpiSnapshotArgs = {
  /** ISO `YYYY-MM-01` — must be the first of a month (backend enforces). */
  periodStart: string
  scope: KpiSnapshotScope
  /** Required when `scope === 'location'`. */
  locationId: string | null
  /**
   * For elevated callers, required when `scope === 'staff'`. For
   * non-elevated callers, pass `null` and the backend resolves the
   * caller's own staff id from `auth.uid()`.
   */
  staffMemberId: string | null
}

function toError(op: string, err: PostgrestError): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

/**
 * Fetch the live KPI snapshot for a given (period, scope) combination.
 * The backend dispatcher (`public.get_kpi_snapshot_live`) validates the
 * scope against the caller's role via `private.kpi_resolve_scope`:
 *   - stylist / assistant → must request `'staff'` scope, staff id
 *     is auto-resolved from `auth.uid()` when NULL.
 *   - manager / admin → may request business / location / staff; the
 *     matching id is required for the non-business scopes.
 */
export async function rpcGetKpiSnapshotLive(
  args: KpiSnapshotArgs,
): Promise<KpiSnapshotRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_kpi_snapshot_live',
    {
      p_period_start: args.periodStart,
      p_scope: args.scope,
      p_location_id: args.locationId,
      p_staff_member_id: args.staffMemberId,
    },
  )
  if (error) throw toError('get_kpi_snapshot_live', error)
  if (data == null) return []
  return Array.isArray(data)
    ? (data as KpiSnapshotRow[])
    : [data as KpiSnapshotRow]
}

/**
 * Fetch the raw rows behind a specific KPI via
 * `public.get_kpi_drilldown_live`. Same auth / scope rules as the
 * snapshot dispatcher — the backend resolves scope once and delegates
 * to the shared `private.debug_kpi_drilldown` body. The return shape
 * is generic so the table renderer does not need per-KPI branches.
 */
export async function rpcGetKpiDrilldownLive(
  args: KpiDrilldownArgs,
): Promise<KpiDrilldownRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_kpi_drilldown_live',
    {
      p_kpi_code: args.kpiCode,
      p_period_start: args.periodStart,
      p_scope: args.scope,
      p_location_id: args.locationId,
      p_staff_member_id: args.staffMemberId,
    },
  )
  if (error) throw toError('get_kpi_drilldown_live', error)
  if (data == null) return []
  return Array.isArray(data)
    ? (data as KpiDrilldownRow[])
    : [data as KpiDrilldownRow]
}
