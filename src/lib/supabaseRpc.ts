/**
 * Sole client-side module for calling Supabase. Use only these RPC wrappers — no direct table/view queries.
 */
import type { PostgrestError } from '@supabase/supabase-js'

import type { AccessProfile } from '@/features/access/types'
import type {
  AdminAccessMappingRow,
  AuthUserSearchRow,
  StaffMemberSearchRow,
} from '@/features/admin/types/accessManagement'
import type { AdminPayrollLineRow, AdminPayrollSummaryRow } from '@/features/admin/types'
import type {
  LocationSalesSummaryKpiRow,
  SalesDailySheetsDataSourceRow,
  WeeklyCommissionLineRow,
  WeeklyCommissionSummaryRow,
} from '@/features/payroll/types'
import { requireSupabaseClient } from '@/lib/supabase'

function toError(op: string, err: PostgrestError): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

function firstRow<T>(data: T | T[] | null): T | null {
  if (data == null) return null
  return Array.isArray(data) ? (data[0] ?? null) : data
}

function asRows<T>(data: T | T[] | null): T[] {
  if (data == null) return []
  return Array.isArray(data) ? data : [data]
}

export async function rpcGetMyAccessProfile(): Promise<AccessProfile | null> {
  const { data, error } = await requireSupabaseClient().rpc('get_my_access_profile')
  if (error) throw toError('get_my_access_profile', error)
  return firstRow(data as AccessProfile | AccessProfile[] | null)
}

/**
 * Returns the logged-in user's `staff_members.fte` or `null`. Scalar
 * SECURITY DEFINER RPC — Supabase serialises numeric as string, so
 * we coerce to `number` here and treat any non-finite result as
 * `null` (same as "no fte recorded"). Consumed by the KPI dashboard
 * to normalise self/staff KPI cards for sub-1.0-FTE stylists.
 */
export async function rpcGetMyFte(): Promise<number | null> {
  const { data, error } = await requireSupabaseClient().rpc('get_my_fte')
  if (error) throw toError('get_my_fte', error)
  if (data == null) return null
  const n = typeof data === 'number' ? data : Number(data as string)
  return Number.isFinite(n) ? n : null
}

/**
 * My Sales metadata: one row per active SalesDailySheets
 * `sales_import_batches` row (source filename + location +
 * row_count + first/last sale date). Drives the "Data source N"
 * line and the per-location sales tiles.
 */
export async function rpcGetSalesDailySheetsDataSources(): Promise<
  SalesDailySheetsDataSourceRow[]
> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_sales_daily_sheets_data_sources',
  )
  if (error) throw toError('get_sales_daily_sheets_data_sources', error)
  return asRows(data as SalesDailySheetsDataSourceRow[])
}

export async function rpcGetMyCommissionSummaryWeekly(): Promise<
  WeeklyCommissionSummaryRow[]
> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_my_commission_summary_weekly',
  )
  if (error) throw toError('get_my_commission_summary_weekly', error)
  return asRows(data as WeeklyCommissionSummaryRow[])
}

/**
 * My Sales KPI tiles: per-location `total_sales_ex_gst` summed across **all**
 * staff for each pay week (same `v_admin_payroll_lines_weekly` basis as
 * Sales Summary). Not scoped to the logged-in stylist.
 */
export async function rpcGetLocationSalesSummaryForMySales(): Promise<
  LocationSalesSummaryKpiRow[]
> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_location_sales_summary_for_my_sales',
  )
  if (error) throw toError('get_location_sales_summary_for_my_sales', error)
  return asRows(data as LocationSalesSummaryKpiRow[])
}

export async function rpcGetMyCommissionLinesWeekly(
  payWeekStart: string,
): Promise<WeeklyCommissionLineRow[]> {
  const { data, error } = await requireSupabaseClient().rpc('get_my_commission_lines_weekly', {
    p_pay_week_start: payWeekStart,
  })
  if (error) throw toError('get_my_commission_lines_weekly', error)
  return asRows(data as WeeklyCommissionLineRow[])
}

export async function rpcGetAdminPayrollSummaryWeekly(): Promise<
  AdminPayrollSummaryRow[]
> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_admin_payroll_summary_weekly',
  )
  if (error) throw toError('get_admin_payroll_summary_weekly', error)
  return asRows(data as AdminPayrollSummaryRow[])
}

export async function rpcGetAdminPayrollLinesWeekly(
  payWeekStart: string,
): Promise<AdminPayrollLineRow[]> {
  const { data, error } = await requireSupabaseClient().rpc('get_admin_payroll_lines_weekly', {
    p_pay_week_start: payWeekStart,
  })
  if (error) throw toError('get_admin_payroll_lines_weekly', error)
  return asRows(data as AdminPayrollLineRow[])
}

export async function rpcGetAdminAccessMappings(): Promise<AdminAccessMappingRow[]> {
  const { data, error } = await requireSupabaseClient().rpc('get_admin_access_mappings')
  if (error) throw toError('get_admin_access_mappings', error)
  return asRows(data as AdminAccessMappingRow[])
}

export async function rpcSearchStaffMembers(
  search: string | null,
): Promise<StaffMemberSearchRow[]> {
  const { data, error } = await requireSupabaseClient().rpc('search_staff_members', {
    p_search: search && search.trim() !== '' ? search.trim() : null,
  })
  if (error) throw toError('search_staff_members', error)
  return asRows(data as StaffMemberSearchRow[])
}

export async function rpcSearchAuthUsers(
  search: string | null,
): Promise<AuthUserSearchRow[]> {
  const { data, error } = await requireSupabaseClient().rpc('search_auth_users', {
    p_search: search && search.trim() !== '' ? search.trim() : null,
  })
  if (error) throw toError('search_auth_users', error)
  return asRows(data as AuthUserSearchRow[])
}

export async function rpcCreateAccessMapping(args: {
  userId: string
  staffMemberId: string | null
  accessRole: string
  isActive?: boolean
}): Promise<string> {
  const { data, error } = await requireSupabaseClient().rpc('create_access_mapping', {
    p_user_id: args.userId,
    p_staff_member_id: args.staffMemberId,
    p_access_role: args.accessRole,
    p_is_active: args.isActive ?? true,
  })
  if (error) throw toError('create_access_mapping', error)
  if (data == null) {
    throw new Error('create_access_mapping: expected mapping id')
  }
  return typeof data === 'string' ? data : String(data)
}

export async function rpcUpdateAccessMapping(args: {
  mappingId: string
  staffMemberId: string | null
  accessRole: string
  isActive: boolean
}): Promise<void> {
  const pMappingId = String(args.mappingId ?? '').trim()
  if (pMappingId === '') {
    throw new Error('update_access_mapping: p_mapping_id is required')
  }
  const { error } = await requireSupabaseClient().rpc('update_access_mapping', {
    p_mapping_id: pMappingId,
    p_staff_member_id: args.staffMemberId,
    p_access_role: args.accessRole,
    p_is_active: args.isActive,
  })
  if (error) throw toError('update_access_mapping', error)
}

export type ImportLocationRow = {
  id: string
  code: string
  name: string
}

export async function rpcListActiveLocationsForImport(): Promise<ImportLocationRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'list_active_locations_for_import',
  )
  if (error) throw toError('list_active_locations_for_import', error)
  return asRows(data as ImportLocationRow[])
}

/** Live first/last sale + location labels from `list_staff_sales_import_metadata` (elevated). */
export type StaffSalesImportMetadataRow = {
  staff_member_id: string
  first_seen_sale_date: string | null
  first_seen_sale_location_names: string | null
  last_seen_sale_date: string | null
  last_seen_sale_location_names: string | null
}

export async function rpcListStaffSalesImportMetadata(): Promise<
  StaffSalesImportMetadataRow[]
> {
  const { data, error } = await requireSupabaseClient().rpc(
    'list_staff_sales_import_metadata',
  )
  if (error) throw toError('list_staff_sales_import_metadata', error)
  return asRows(data as StaffSalesImportMetadataRow[])
}

/**
 * After uploading a CSV to Storage, call your server-side import pipeline.
 * `p_location_id` is required (Admin Imports location selector).
 */
export async function rpcTriggerSalesDailySheetsImport(args: {
  pStoragePath: string
  pLocationId: string
}): Promise<unknown> {
  const { data, error } = await requireSupabaseClient()
    .rpc('trigger_sales_daily_sheets_import', {
      p_storage_path: args.pStoragePath,
      p_location_id: args.pLocationId,
    })
    .abortSignal(AbortSignal.timeout(30_000))
  if (error) throw toError('trigger_sales_daily_sheets_import', error)
  return data
}

export type SalesDailySheetsImportBatchRow = {
  id: string
  storage_path: string
  status: string | null
  message: string | null
  rows_staged: number | null
  rows_loaded: number | null
  error_message: string | null
}

export async function fetchSalesDailySheetsImportBatch(
  batchId: string,
): Promise<SalesDailySheetsImportBatchRow> {
  const { data, error } = await requireSupabaseClient()
    .from('sales_daily_sheets_import_batches')
    .select('id, storage_path, status, message, rows_staged, rows_loaded, error_message')
    .eq('id', batchId)
    .single()
  if (error) throw toError('sales_daily_sheets_import_batches', error)
  return data as SalesDailySheetsImportBatchRow
}

/** Destructive: removes all Sales Daily Sheets import data (elevated users only). */
export async function rpcDeleteAllSalesDailySheetsImportData(): Promise<unknown> {
  const { data, error } = await requireSupabaseClient().rpc(
    'delete_all_sales_daily_sheets_import_data',
  )
  if (error) throw toError('delete_all_sales_daily_sheets_import_data', error)
  return data
}

/**
 * Browser-side Sales Daily Sheets staged-row helpers. Edge-Function CPU
 * limits make per-row parsing in Edge unsafe for large files, so the
 * client now does the parsing and writes staged rows directly via these
 * RPCs. Each RPC enforces elevated access (manager/admin/superadmin) +
 * batch-creator on the database side, so even though they're callable
 * by `authenticated`, stylist/assistant users cannot reach them.
 */
export async function rpcDeleteSalesDailySheetsStagedRowsForBatch(
  batchId: string,
): Promise<void> {
  const { error } = await requireSupabaseClient().rpc(
    'delete_sales_daily_sheets_staged_rows_for_batch',
    { p_batch_id: batchId },
  )
  if (error) throw toError('delete_sales_daily_sheets_staged_rows_for_batch', error)
}

/** All rows in `rows` must reference the same `batch_id` (the SQL guard enforces this). */
export async function rpcInsertSalesDailySheetsStagedRowsChunk(
  rows: Array<Record<string, unknown>>,
): Promise<void> {
  if (rows.length === 0) return
  const { error } = await requireSupabaseClient().rpc(
    'insert_sales_daily_sheets_staged_rows_chunk',
    { p_rows: rows },
  )
  if (error) throw toError('insert_sales_daily_sheets_staged_rows_chunk', error)
}

export async function rpcApplySalesDailySheetsToPayroll(batchId: string): Promise<void> {
  const { error } = await requireSupabaseClient()
    .rpc('apply_sales_daily_sheets_to_payroll', { p_batch_id: batchId })
    // Apply RPC does heavy SQL with statement_timeout disabled; use a generous wall-clock budget.
    .abortSignal(AbortSignal.timeout(15 * 60_000))
  if (error) throw toError('apply_sales_daily_sheets_to_payroll', error)
}

export type SalesDailySheetsBatchStatus = 'queued' | 'processing' | 'completed' | 'failed'

export async function rpcSetSalesDailySheetsBatchStatus(args: {
  batchId: string
  status: SalesDailySheetsBatchStatus
  message?: string | null
  errorMessage?: string | null
  rowsStaged?: number | null
  rowsLoaded?: number | null
}): Promise<void> {
  const { error } = await requireSupabaseClient().rpc(
    'set_sales_daily_sheets_batch_status',
    {
      p_batch_id: args.batchId,
      p_status: args.status,
      p_message: args.message ?? null,
      p_error_message: args.errorMessage ?? null,
      p_rows_staged: args.rowsStaged ?? null,
      p_rows_loaded: args.rowsLoaded ?? null,
    },
  )
  if (error) throw toError('set_sales_daily_sheets_batch_status', error)
}
