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

function coerceNullableRpcNumber(data: unknown): number | null {
  if (data == null) return null
  const n = typeof data === 'number' ? data : Number(data as string)
  return Number.isFinite(n) ? n : null
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
  return coerceNullableRpcNumber(data)
}

/**
 * FTE for a staff member (admin/manager staff KPI view). Same numeric
 * coercion as `rpcGetMyFte`. Backend enforces role + id rules.
 */
export async function rpcGetStaffFteForKpiDisplay(
  staffMemberId: string,
): Promise<number | null> {
  const id = String(staffMemberId ?? '').trim()
  if (id === '') return null
  const { data, error } = await requireSupabaseClient().rpc(
    'get_staff_fte_for_kpi_display',
    { p_staff_member_id: id },
  )
  if (error) throw toError('get_staff_fte_for_kpi_display', error)
  return coerceNullableRpcNumber(data)
}

/**
 * My Sales / Sales Summary metadata: calls
 * `get_sales_daily_sheets_data_sources_by_location` — one row per location
 * (aggregated SalesDailySheets-backed `sales_transactions`: row_count,
 * min/max sale_date). Drives the "Data - {Location}" lines and per-location
 * sales tiles.
 */
export async function rpcGetSalesDailySheetsDataSources(): Promise<
  SalesDailySheetsDataSourceRow[]
> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_sales_daily_sheets_data_sources_by_location',
  )
  if (error) throw toError('get_sales_daily_sheets_data_sources_by_location', error)
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

export type SalesDailySheetsImportResult = {
  selected_location_name?: string | null
  date_range_start?: string | null
  date_range_end?: string | null
  csv_rows_read?: number | null
  csv_rows_staged?: number | null
  existing_rows_before_import?: number | null
  existing_rows_replaced?: number | null
  existing_rows_unchanged?: number | null
  rows_loaded?: number | null
  sales_transactions_created?: number | null
}

export type SalesDailySheetsImportBatchRow = {
  id: string
  storage_path: string
  status: string | null
  message: string | null
  rows_staged: number | null
  rows_loaded: number | null
  error_message: string | null
  import_result?: SalesDailySheetsImportResult | null
}

export async function fetchSalesDailySheetsImportBatch(
  batchId: string,
): Promise<SalesDailySheetsImportBatchRow> {
  const { data, error } = await requireSupabaseClient()
    .from('sales_daily_sheets_import_batches')
    .select(
      'id, storage_path, status, message, rows_staged, rows_loaded, error_message, import_result',
    )
    .eq('id', batchId)
    .single()
  if (error) throw toError('sales_daily_sheets_import_batches', error)
  return data as SalesDailySheetsImportBatchRow
}

function postgrestErrorDetailMessage(err: PostgrestError): string {
  const parts: string[] = []
  if (err.message) parts.push(err.message)
  if (err.details) parts.push(`Details: ${err.details}`)
  if (err.hint) parts.push(`Hint: ${err.hint}`)
  if (err.code) parts.push(`Code: ${err.code}`)
  return parts.join('\n')
}

export type DeleteSalesDailySheetsImportDataResult = {
  status: string
  message: string
  location_id: string | null
  location_name: string
  transactions_deleted: number
  raw_rows_deleted: number
  sales_import_batches_deleted: number
  staged_rows_deleted: number
  staged_batches_deleted: number
  deleted_at: string
}

function parseDeleteSalesDailySheetsImportDataResult(
  data: unknown,
): DeleteSalesDailySheetsImportDataResult {
  let parsed: unknown = data
  if (typeof parsed === 'string') {
    try {
      parsed = JSON.parse(parsed) as unknown
    } catch {
      throw new Error(
        'Unexpected response from delete_all_sales_daily_sheets_import_data (invalid JSON)',
      )
    }
  }
  if (parsed == null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Unexpected response from delete_all_sales_daily_sheets_import_data')
  }
  const o = parsed as Record<string, unknown>
  const num = (v: unknown) =>
    typeof v === 'number' && Number.isFinite(v)
      ? v
      : typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))
        ? Number(v)
        : 0
  const tx =
    o.transactions_deleted != null
      ? num(o.transactions_deleted)
      : num(o.sales_transactions_deleted)
  const raw =
    o.raw_rows_deleted != null ? num(o.raw_rows_deleted) : num(o.raw_sales_import_rows_deleted)
  const batches = num(o.sales_import_batches_deleted)
  const staged =
    o.staged_rows_deleted != null
      ? num(o.staged_rows_deleted)
      : num(o.sales_daily_sheets_staged_rows_deleted)
  const sheetBatches =
    o.staged_batches_deleted != null
      ? num(o.staged_batches_deleted)
      : num(o.sales_daily_sheets_import_batches_deleted)
  return {
    status: typeof o.status === 'string' ? o.status : 'ok',
    message: typeof o.message === 'string' ? o.message : '',
    location_id:
      o.location_id == null || o.location_id === '' ? null : String(o.location_id),
    location_name:
      typeof o.location_name === 'string' && o.location_name.trim() !== ''
        ? o.location_name.trim()
        : o.location_id == null || o.location_id === ''
          ? 'All locations'
          : String(o.location_id),
    transactions_deleted: tx,
    raw_rows_deleted: raw,
    sales_import_batches_deleted: batches,
    staged_rows_deleted: staged,
    staged_batches_deleted: sheetBatches,
    deleted_at:
      typeof o.deleted_at === 'string'
        ? o.deleted_at
        : o.deleted_at != null
          ? String(o.deleted_at)
          : '',
  }
}

/** Destructive: removes Sales Daily Sheets import data (elevated users only). Null = all salons. */
export async function rpcDeleteAllSalesDailySheetsImportData(args: {
  p_location_id?: string | null
}): Promise<DeleteSalesDailySheetsImportDataResult> {
  const { data, error } = await requireSupabaseClient()
    .rpc('delete_all_sales_daily_sheets_import_data', {
      p_location_id: args.p_location_id ?? null,
    })
    .abortSignal(AbortSignal.timeout(60 * 60_000))
  if (error) throw new Error(postgrestErrorDetailMessage(error))
  return parseDeleteSalesDailySheetsImportDataResult(data)
}

export type RebuildSalesDailySheetsReportingResult = {
  status: string
  message: string
  location_id: string | null
  batches_rebuilt: number
  transactions_deleted: number
  transactions_created: number
  rebuilt_at: string
}

function isMissingRebuildSalesRpcError(err: PostgrestError): boolean {
  const m = (err.message ?? '').toLowerCase()
  const c = err.code ?? ''
  return (
    c === 'PGRST202' ||
    c === '42883' ||
    (m.includes('could not find') && m.includes('function')) ||
    (m.includes('schema cache') && m.includes('function')) ||
    (m.includes('does not exist') &&
      (m.includes('rebuild_sales_daily_sheets_reporting_data') ||
        m.includes('list_sales_daily_sheets_rebuild_batches') ||
        m.includes('rebuild_sales_daily_sheets_reporting_batch')))
  )
}

function throwFromRebuildSalesRpcError(error: PostgrestError): never {
  const detail = postgrestErrorDetailMessage(error)
  if (isMissingRebuildSalesRpcError(error)) {
    throw new Error(
      'Rebuild RPC is not available. Push the latest database migration first.\n\n' + detail,
    )
  }
  throw new Error(detail)
}

function parseRebuildSalesDailySheetsReportingResult(
  data: unknown,
): RebuildSalesDailySheetsReportingResult {
  let parsed: unknown = data
  if (typeof parsed === 'string') {
    try {
      parsed = JSON.parse(parsed) as unknown
    } catch {
      throw new Error(
        'Unexpected response from rebuild_sales_daily_sheets_reporting_data (invalid JSON)',
      )
    }
  }
  if (parsed == null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Unexpected response from rebuild_sales_daily_sheets_reporting_data')
  }
  const o = parsed as Record<string, unknown>
  const num = (v: unknown) =>
    typeof v === 'number' && Number.isFinite(v)
      ? v
      : typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))
        ? Number(v)
        : 0
  return {
    status: typeof o.status === 'string' ? o.status : 'unknown',
    message: typeof o.message === 'string' ? o.message : '',
    location_id:
      o.location_id == null || o.location_id === ''
        ? null
        : String(o.location_id),
    batches_rebuilt: num(o.batches_rebuilt),
    transactions_deleted: num(o.transactions_deleted),
    transactions_created: num(o.transactions_created),
    rebuilt_at:
      typeof o.rebuilt_at === 'string'
        ? o.rebuilt_at
        : o.rebuilt_at != null
          ? String(o.rebuilt_at)
          : '',
  }
}

/**
 * Rebuild `sales_transactions` from existing `raw_sales_import_rows` for
 * Sales Daily Sheets import batches (elevated users only). Does not
 * delete raw or staged data.
 */
export async function rpcRebuildSalesDailySheetsReportingData(args: {
  p_location_id?: string | null
}): Promise<RebuildSalesDailySheetsReportingResult> {
  const { data, error } = await requireSupabaseClient()
    .rpc('rebuild_sales_daily_sheets_reporting_data', {
      p_location_id: args.p_location_id ?? null,
    })
    .abortSignal(AbortSignal.timeout(15 * 60_000))
  if (error) throwFromRebuildSalesRpcError(error)
  return parseRebuildSalesDailySheetsReportingResult(data)
}

export type SalesDailySheetsRebuildBatchRow = {
  batch_id: string
  location_id: string
  location_name: string
  source_file_name: string
  raw_rows: number
  existing_transactions: number
  created_at: string | null
}

function parseSalesDailySheetsRebuildBatchRow(row: unknown): SalesDailySheetsRebuildBatchRow {
  if (row == null || typeof row !== 'object' || Array.isArray(row)) {
    throw new Error('Unexpected row from list_sales_daily_sheets_rebuild_batches')
  }
  const o = row as Record<string, unknown>
  const num = (v: unknown) =>
    typeof v === 'number' && Number.isFinite(v)
      ? v
      : typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))
        ? Number(v)
        : 0
  return {
    batch_id: o.batch_id != null ? String(o.batch_id) : '',
    location_id: o.location_id != null ? String(o.location_id) : '',
    location_name: typeof o.location_name === 'string' ? o.location_name : '',
    source_file_name: typeof o.source_file_name === 'string' ? o.source_file_name : '',
    raw_rows: num(o.raw_rows),
    existing_transactions: num(o.existing_transactions),
    created_at:
      o.created_at == null
        ? null
        : typeof o.created_at === 'string'
          ? o.created_at
          : String(o.created_at),
  }
}

/** Lists SalesDailySheets import batches eligible for rebuild (elevated users only). */
export async function rpcListSalesDailySheetsRebuildBatches(args: {
  p_location_id?: string | null
}): Promise<SalesDailySheetsRebuildBatchRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'list_sales_daily_sheets_rebuild_batches',
    { p_location_id: args.p_location_id ?? null },
  )
  if (error) throwFromRebuildSalesRpcError(error)
  return asRows(data as unknown).map(parseSalesDailySheetsRebuildBatchRow)
}

export type RebuildSalesDailySheetsReportingBatchResult = {
  status: string
  batch_id: string
  location_id: string | null
  location_name: string
  source_file_name: string
  transactions_deleted: number
  transactions_created: number
  rebuilt_at: string
}

function parseRebuildSalesDailySheetsReportingBatchResult(
  data: unknown,
): RebuildSalesDailySheetsReportingBatchResult {
  let parsed: unknown = data
  if (typeof parsed === 'string') {
    try {
      parsed = JSON.parse(parsed) as unknown
    } catch {
      throw new Error(
        'Unexpected response from rebuild_sales_daily_sheets_reporting_batch (invalid JSON)',
      )
    }
  }
  if (parsed == null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new Error('Unexpected response from rebuild_sales_daily_sheets_reporting_batch')
  }
  const o = parsed as Record<string, unknown>
  const num = (v: unknown) =>
    typeof v === 'number' && Number.isFinite(v)
      ? v
      : typeof v === 'string' && v.trim() !== '' && Number.isFinite(Number(v))
        ? Number(v)
        : 0
  return {
    status: typeof o.status === 'string' ? o.status : 'unknown',
    batch_id: o.batch_id != null ? String(o.batch_id) : '',
    location_id:
      o.location_id == null || o.location_id === '' ? null : String(o.location_id),
    location_name: typeof o.location_name === 'string' ? o.location_name : '',
    source_file_name: typeof o.source_file_name === 'string' ? o.source_file_name : '',
    transactions_deleted: num(o.transactions_deleted),
    transactions_created: num(o.transactions_created),
    rebuilt_at:
      typeof o.rebuilt_at === 'string'
        ? o.rebuilt_at
        : o.rebuilt_at != null
          ? String(o.rebuilt_at)
          : '',
  }
}

/** Rebuild one SalesDailySheets import batch (elevated users only). */
export async function rpcRebuildSalesDailySheetsReportingBatch(
  batchId: string,
): Promise<RebuildSalesDailySheetsReportingBatchResult> {
  const id = String(batchId ?? '').trim()
  if (id === '') throw new Error('batch_id is required')
  const { data, error } = await requireSupabaseClient()
    .rpc('rebuild_sales_daily_sheets_reporting_batch', { p_batch_id: id })
    .abortSignal(AbortSignal.timeout(15 * 60_000))
  if (error) throwFromRebuildSalesRpcError(error)
  return parseRebuildSalesDailySheetsReportingBatchResult(data)
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
  /** Merged into sales_daily_sheets_import_batches.import_result (server JSON). */
  importResult?: Record<string, unknown> | null
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
      p_import_result: args.importResult ?? null,
    },
  )
  if (error) throw toError('set_sales_daily_sheets_batch_status', error)
}
