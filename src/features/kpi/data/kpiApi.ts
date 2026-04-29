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

/**
 * One row returned by `public.get_kpi_stylist_comparisons_live`. Drives
 * the optional comparison note + value tint on KPI cards in staff/self
 * view. Numeric columns may arrive as `number` or `string` depending
 * on PostgREST encoding — normalise at the call site via `Number(...)`.
 */
export type KpiStylistComparisonRow = {
  kpi_code: string
  period_start: string
  period_end: string
  mtd_through: string
  is_current_open_month: boolean
  staff_member_id: string | null
  current_value: number | string | null
  highest_value: number | string | null
  average_value: number | string | null
  cohort_size: number | string
  is_highest: boolean
  is_above_average: boolean
}

export type KpiStylistComparisonsArgs = {
  /** ISO `YYYY-MM-01` — backend rejects non-month-starts. */
  periodStart: string
  /** Backend currently only returns rows for `'staff'`. */
  scope: KpiSnapshotScope
  locationId: string | null
  /**
   * For elevated callers, required when `scope === 'staff'`. For
   * non-elevated callers, pass `null` and the backend resolves the
   * caller's own staff id from `auth.uid()`.
   */
  staffMemberId: string | null
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
  /**
   * When `true`, requests all 11 KPIs (same as calling the RPC with
   * `p_include_extended` omitted or true). When `false` or omitted here,
   * the client sends `p_include_extended: false` for a fast six-KPI snapshot.
   */
  includeExtended?: boolean
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
 *
 * Pass `includeExtended: true` for all 11 KPIs; omit or pass `false` to
 * skip retention/frequency (six core KPIs only).
 */
export async function rpcGetKpiSnapshotLive(
  args: KpiSnapshotArgs,
): Promise<KpiSnapshotRow[]> {
  const includeExtended = args.includeExtended ?? false
  const { data, error } = await requireSupabaseClient().rpc(
    'get_kpi_snapshot_live',
    {
      p_period_start: args.periodStart,
      p_scope: args.scope,
      p_location_id: args.locationId,
      p_staff_member_id: args.staffMemberId,
      p_include_extended: includeExtended,
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
/**
 * Fetch the stylist comparison set for the staff/self KPI dashboard
 * via `public.get_kpi_stylist_comparisons_live`. Returns one row per
 * supported KPI (revenue, guests_per_month, new_clients_per_month,
 * average_client_spend, assistant_utilisation_ratio — see
 * `get_kpi_stylist_comparisons_live` migrations) with `current_value`, `highest_value`,
 * `average_value` plus `is_highest` / `is_above_average` flags.
 * Revenue, guests, and new-clients rows use FTE-scaled comparison
 * values (raw/fte when 0 < fte < 1 per cohort member) so self-view
 * badges match normalised card values; average spend and assistant
 * utilisation stay unscaled rates.
 *
 * Returns `[]` when the resolved scope is not staff (the backend
 * RPC explicitly returns zero rows in that case).
 */
export async function rpcGetKpiStylistComparisonsLive(
  args: KpiStylistComparisonsArgs,
): Promise<KpiStylistComparisonRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_kpi_stylist_comparisons_live',
    {
      p_period_start: args.periodStart,
      p_scope: args.scope,
      p_location_id: args.locationId,
      p_staff_member_id: args.staffMemberId,
    },
  )
  if (error) throw toError('get_kpi_stylist_comparisons_live', error)
  if (data == null) return []
  return Array.isArray(data)
    ? (data as KpiStylistComparisonRow[])
    : [data as KpiStylistComparisonRow]
}

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

/**
 * One line returned by `public.get_invoice_detail_live`. Backs the
 * invoice-detail popup opened from the KPI underlying-rows table on
 * sales-line KPIs (revenue / assistant_utilisation_ratio). Numeric
 * columns may arrive as `number` or `string` — normalise at the call
 * site via `Number(...)`.
 */
export type KpiInvoiceDetailRow = {
  invoice: string
  sale_date: string | null
  sale_datetime: string | null
  location_id: string | null
  customer_name: string | null
  product_service_name: string | null
  product_type_actual: string | null
  price_ex_gst: number | string | null
  commission_owner_candidate_id: string | null
  commission_owner_candidate_name: string | null
  staff_work_id: string | null
  staff_work_name: string | null
  staff_work_display_name: string | null
  staff_work_full_name: string | null
  staff_work_primary_role: string | null
  assistant_redirect_candidate: boolean | null
}

export type KpiInvoiceDetailArgs = {
  invoice: string
  locationId: string | null
  saleDate: string | null
}

/**
 * Fetch every line on an invoice tuple. The KPI drilldown popup calls
 * this with (invoice, location_id, sale_date) copied verbatim from the
 * drilldown row's raw_payload. The backend RPC is SECURITY DEFINER so
 * non-elevated users who can see the row in the drilldown can also
 * open its invoice popup.
 */
export async function rpcGetInvoiceDetailLive(
  args: KpiInvoiceDetailArgs,
): Promise<KpiInvoiceDetailRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_invoice_detail_live',
    {
      p_invoice: args.invoice,
      p_location_id: args.locationId,
      p_sale_date: args.saleDate,
    },
  )
  if (error) throw toError('get_invoice_detail_live', error)
  if (data == null) return []
  return Array.isArray(data)
    ? (data as KpiInvoiceDetailRow[])
    : [data as KpiInvoiceDetailRow]
}
