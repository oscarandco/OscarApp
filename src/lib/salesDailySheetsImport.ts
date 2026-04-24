import Papa, { type ParseError, type ParseResult } from 'papaparse'

import {
  getSalesDailySheetsBucket,
  getSalesDailySheetsPathPrefix,
} from '@/lib/env'
import { requireSupabaseClient } from '@/lib/supabase'
import type { ImportLocationRow } from '@/lib/supabaseRpc'
import {
  fetchSalesDailySheetsImportBatch,
  rpcApplySalesDailySheetsToPayroll,
  rpcDeleteSalesDailySheetsStagedRowsForBatch,
  rpcInsertSalesDailySheetsStagedRowsChunk,
  rpcSetSalesDailySheetsBatchStatus,
  rpcTriggerSalesDailySheetsImport,
  type SalesDailySheetsImportBatchRow,
} from '@/lib/supabaseRpc'

function sanitizeFileName(name: string): string {
  const base = name.split(/[/\\]/).pop() ?? 'upload.csv'
  return base.replace(/[^a-zA-Z0-9._-]+/g, '_').slice(0, 200) || 'upload.csv'
}

/**
 * Match filename to Orewa / Takapuna using the same codes as `get_location_id_from_filename` (ORE / TAK).
 */
export function guessLocationIdFromFileName(
  fileName: string,
  locations: ImportLocationRow[],
): string | null {
  const lower = fileName.toLowerCase()
  if (lower.includes('orewa')) {
    const byCode = locations.find((l) => l.code === 'ORE')
    if (byCode) return byCode.id
    const byName = locations.find((l) => l.name.toLowerCase().includes('orewa'))
    return byName?.id ?? null
  }
  if (lower.includes('takapuna')) {
    const byCode = locations.find((l) => l.code === 'TAK')
    if (byCode) return byCode.id
    const byName = locations.find((l) => l.name.toLowerCase().includes('takapuna'))
    return byName?.id ?? null
  }
  return null
}

export function isLikelyCsvFile(file: File): boolean {
  const n = file.name.toLowerCase()
  if (n.endsWith('.csv')) return true
  const t = file.type.toLowerCase()
  return t === 'text/csv' || t === 'application/csv' || t === 'text/plain'
}

type TriggerJson = {
  success?: boolean
  status?: string
  batch_id?: string
  storage_path?: string
  message?: string
  error_message?: string | null
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return v !== null && typeof v === 'object'
}

async function sleep(ms: number): Promise<void> {
  await new Promise((r) => setTimeout(r, ms))
}

async function pollSalesDailySheetsBatchUntilTerminal(
  batchId: string,
  opts: {
    maxMs: number
    intervalMs: number
    onPoll?: (row: SalesDailySheetsImportBatchRow) => void
  },
): Promise<SalesDailySheetsImportBatchRow> {
  const start = Date.now()
  while (Date.now() - start < opts.maxMs) {
    const row = await fetchSalesDailySheetsImportBatch(batchId)
    opts.onPoll?.(row)
    const s = (row.status ?? '').toLowerCase()
    if (s === 'completed' || s === 'failed') return row
    await sleep(opts.intervalMs)
  }
  const last = await fetchSalesDailySheetsImportBatch(batchId)
  opts.onPoll?.(last)
  const s = (last.status ?? '').toLowerCase()
  if (s === 'completed' || s === 'failed') return last
  throw new Error(
    `Import did not finish within ${Math.round(opts.maxMs / 60_000)} minutes (last status: ${last.status ?? 'unknown'}).`,
  )
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

/**
 * Send up to this many staged rows in a single PostgREST call. Larger
 * chunks = fewer round trips but heavier per-call JSON; 500 matched the
 * Edge implementation and stays well under PostgREST request limits.
 */
const STAGED_INSERT_CHUNK_SIZE = 500

function normHeader(s: string): string {
  return s.trim().toLowerCase().replace(/\s+/g, ' ')
}

function pick(row: Record<string, string>, ...keys: string[]): string | undefined {
  const lower = new Map<string, string>()
  for (const [k, v] of Object.entries(row)) {
    lower.set(normHeader(k), v)
  }
  for (const key of keys) {
    const v = lower.get(normHeader(key))
    if (v !== undefined && String(v).trim() !== '') return String(v)
  }
  return undefined
}

function parseNum(s: string | undefined): number | null {
  if (s == null || s === '') return null
  const n = Number(String(s).replace(/[^0-9.-]/g, ''))
  return Number.isFinite(n) ? n : null
}

function parseDate(s: string | undefined): string | null {
  if (s == null || s === '') return null
  const t = s.trim()
  if (/^\d{4}-\d{2}-\d{2}/.test(t)) return t.slice(0, 10)
  const d = new Date(t)
  if (Number.isNaN(d.getTime())) return null
  return d.toISOString().slice(0, 10)
}

/**
 * Map one raw CSV record into the staged-row JSON shape consumed by
 * `insert_sales_daily_sheets_staged_rows_chunk`. Mapping is preserved
 * verbatim from the Edge Function's `mapRowToStagedRow`.
 */
function mapRowToStagedRow(args: {
  row: Record<string, string>
  lineNumber: number
  batchId: string
  forcedLocation: string
}): Record<string, unknown> {
  const { row, lineNumber, batchId, forcedLocation } = args

  const invoice = pick(row, 'invoice', 'invoice #', 'invoice_no', 'invoice number')
  const saleDate = pick(row, 'sale date', 'sale_date', 'date')
  const payWeekStart = pick(row, 'pay week start', 'pay_week_start')
  const payWeekEnd = pick(row, 'pay week end', 'pay_week_end')
  const payDate = pick(row, 'pay date', 'pay_date')
  const customerName = pick(row, 'customer', 'customer name', 'customer_name')
  const productService = pick(
    row,
    'product service name',
    'product_service_name',
    'service',
    'product',
  )
  const quantity = pick(row, 'quantity', 'qty')
  const priceExGst = pick(row, 'price ex gst', 'price_ex_gst', 'price ex gst ($)', 'price')
  const staffPaid = pick(
    row,
    'derived_staff_paid_display_name',
    'staff paid',
    'stylist',
    'staff',
  )
  const actualComm = pick(
    row,
    'actual_commission_amount',
    'actual commission',
    'commission',
  )
  const asstComm = pick(row, 'assistant_commission_amount', 'assistant commission')
  const payrollStatus = pick(row, 'payroll status', 'payroll_status')
  const stylistNote = pick(row, 'stylist visible note', 'stylist_visible_note', 'note')
  const locationId = pick(row, 'location_id', 'location id')

  return {
    batch_id: batchId,
    line_number: lineNumber,
    invoice: invoice ?? null,
    sale_date: saleDate ?? null,
    pay_week_start: parseDate(payWeekStart),
    pay_week_end: parseDate(payWeekEnd),
    pay_date: parseDate(payDate),
    customer_name: customerName ?? null,
    product_service_name: productService ?? null,
    quantity: parseNum(quantity),
    price_ex_gst: parseNum(priceExGst),
    derived_staff_paid_display_name: staffPaid ?? null,
    actual_commission_amount: parseNum(actualComm),
    assistant_commission_amount: parseNum(asstComm),
    payroll_status: payrollStatus ?? null,
    stylist_visible_note: stylistNote ?? null,
    location_id:
      forcedLocation && UUID_RE.test(forcedLocation)
        ? forcedLocation
        : locationId && UUID_RE.test(locationId)
          ? locationId
          : null,
    extras: row as unknown as Record<string, unknown>,
  }
}

function isAllBlank(row: Record<string, string>): boolean {
  for (const v of Object.values(row)) {
    if (v != null && String(v).trim() !== '') return false
  }
  return true
}

/**
 * Parse the CSV with PapaParse in `chunk` mode and stage rows directly
 * against the existing staging RPCs. Headers come from PapaParse's
 * `header: true` option; we coerce field names by trimming/lower-casing
 * inside `pick` so the existing column-name tolerance is preserved.
 *
 * `worker: true` keeps parsing off the main thread for large files
 * without changing the public contract here.
 */
async function parseAndStageCsvInBrowser(args: {
  file: File
  batchId: string
  locationId: string
  onProgress?: (rowsStaged: number) => void
}): Promise<{ rowsStaged: number }> {
  const { file, batchId, locationId, onProgress } = args

  let lineNumber = 0
  let totalStaged = 0
  let buffer: Array<Record<string, unknown>> = []
  // Chained promise so chunk inserts run sequentially and any error
  // surfaces by rejecting the chain (we await it at the end).
  let inflight: Promise<void> = Promise.resolve()
  let aborted = false
  let firstError: Error | null = null

  const flushBuffer = (): void => {
    if (buffer.length === 0) return
    const batch = buffer
    buffer = []
    inflight = inflight.then(async () => {
      if (aborted) return
      try {
        await rpcInsertSalesDailySheetsStagedRowsChunk(batch)
        totalStaged += batch.length
        onProgress?.(totalStaged)
      } catch (e) {
        aborted = true
        firstError = e instanceof Error ? e : new Error(String(e))
        throw firstError
      }
    })
  }

  await new Promise<void>((resolve, reject) => {
    Papa.parse<Record<string, string>>(file, {
      header: true,
      skipEmptyLines: 'greedy',
      worker: true,
      chunkSize: 1024 * 1024, // 1 MiB chunks of source bytes; tunes parser memory only.
      chunk: (results: ParseResult<Record<string, string>>, parser) => {
        if (aborted) {
          parser.abort()
          return
        }
        try {
          for (const raw of results.data) {
            if (!raw || isAllBlank(raw)) continue
            lineNumber += 1
            const staged = mapRowToStagedRow({
              row: raw,
              lineNumber,
              batchId,
              forcedLocation: locationId,
            })
            buffer.push(staged)
            if (buffer.length >= STAGED_INSERT_CHUNK_SIZE) {
              flushBuffer()
            }
          }
        } catch (e) {
          aborted = true
          firstError = e instanceof Error ? e : new Error(String(e))
          parser.abort()
          reject(firstError)
        }
      },
      complete: () => {
        flushBuffer()
        inflight.then(resolve, reject)
      },
      error: (err: Error | ParseError) => {
        aborted = true
        const msg = err instanceof Error ? err.message : (err.message ?? String(err))
        reject(new Error(`CSV parse failed: ${msg}`))
      },
    })
  })

  if (firstError) throw firstError

  return { rowsStaged: totalStaged }
}

/**
 * Upload CSV to the configured bucket, queue a batch via RPC, parse the
 * file in the browser, stage rows in chunks, then run the apply RPC and
 * mark the batch terminal. Edge Function is left in place but not
 * invoked.
 */
export async function uploadAndTriggerSalesDailySheetsImport(
  file: File,
  locationId: string,
  options?: {
    onUploaded?: (objectPath: string) => void
    /** After the queue RPC returns a queued batch (before staged-row work). */
    onQueueRegistered?: (batchId: string) => void
    /**
     * Backwards-compatible callback name. Fired once the browser has
     * finished staging rows and is about to call the apply RPC; lets
     * the page UX advance from "in progress" to "applying".
     */
    onEdgeAccepted?: () => void
    /** Each poll tick while waiting for a terminal batch status. */
    onBatchPoll?: (row: SalesDailySheetsImportBatchRow) => void
  },
): Promise<{
  storagePath: string
  batchId: string | null
  pipelineResult: unknown
  batchRow: SalesDailySheetsImportBatchRow | null
}> {
  if (!locationId || locationId.trim() === '') {
    throw new Error('locationId is required for Sales Daily Sheets import')
  }
  const client = requireSupabaseClient()
  const bucket = getSalesDailySheetsBucket()
  const prefix = getSalesDailySheetsPathPrefix()
  const objectPath = `${prefix}${Date.now()}_${sanitizeFileName(file.name)}`

  const { error: uploadError } = await client.storage
    .from(bucket)
    .upload(objectPath, file, {
      cacheControl: '3600',
      upsert: false,
      contentType: file.type || 'text/csv',
    })

  if (uploadError) {
    throw uploadError
  }

  options?.onUploaded?.(objectPath)

  const pipelineResult = await rpcTriggerSalesDailySheetsImport({
    pStoragePath: objectPath,
    pLocationId: locationId,
  })

  const pj = isRecord(pipelineResult) ? (pipelineResult as TriggerJson) : null
  const status = pj?.status?.toLowerCase() ?? ''
  const batchId = typeof pj?.batch_id === 'string' ? pj.batch_id : null

  if (!batchId) {
    return { storagePath: objectPath, batchId: null, pipelineResult, batchRow: null }
  }

  if (status === 'queued' && pj?.success === true) {
    options?.onQueueRegistered?.(batchId)

    try {
      // 1) Mark batch as processing so the polling page reflects activity.
      await rpcSetSalesDailySheetsBatchStatus({
        batchId,
        status: 'processing',
        message: 'Import in progress (browser)',
        errorMessage: null,
      })

      // 2) Belt-and-braces: clear any prior staged rows for this batch
      //    so a retry starts from a clean state.
      await rpcDeleteSalesDailySheetsStagedRowsForBatch(batchId)

      // 3) Parse + stage rows in chunks.
      const { rowsStaged } = await parseAndStageCsvInBrowser({
        file,
        batchId,
        locationId,
      })

      if (rowsStaged === 0) {
        throw new Error('No data rows in CSV')
      }

      // Surface the staged count + advance UX before the heavy apply RPC runs.
      await rpcSetSalesDailySheetsBatchStatus({
        batchId,
        status: 'processing',
        message: `Applying ${rowsStaged} staged rows`,
        rowsStaged,
      })
      options?.onEdgeAccepted?.()

      // 4) Apply staged rows into payroll/transaction tables.
      await rpcApplySalesDailySheetsToPayroll(batchId)

      // 5) Mark completed (rows_loaded is already set by apply RPC).
      const finalRow = await fetchSalesDailySheetsImportBatch(batchId)
      const finalLoaded =
        typeof finalRow.rows_loaded === 'number' ? finalRow.rows_loaded : null
      await rpcSetSalesDailySheetsBatchStatus({
        batchId,
        status: 'completed',
        message: 'Import completed',
        errorMessage: null,
        rowsStaged,
        rowsLoaded: finalLoaded ?? rowsStaged,
      })
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e)
      try {
        await rpcSetSalesDailySheetsBatchStatus({
          batchId,
          status: 'failed',
          message: 'Import failed',
          errorMessage: msg,
        })
      } catch {
        // best-effort
      }
      throw e instanceof Error ? e : new Error(msg)
    }

    // Poll once to fetch the final row and run the existing onBatchPoll callback
    // so the page UX (last-updated, rows_loaded) refreshes through the same path.
    const batchRow = await pollSalesDailySheetsBatchUntilTerminal(batchId, {
      maxMs: 60_000,
      intervalMs: 500,
      onPoll: options?.onBatchPoll,
    })

    const terminal = (batchRow.status ?? '').toLowerCase()
    if (terminal === 'failed') {
      throw new Error(batchRow.error_message ?? batchRow.message ?? 'Import failed')
    }

    return {
      storagePath: objectPath,
      batchId,
      pipelineResult,
      batchRow,
    }
  }

  const batchRow = await fetchSalesDailySheetsImportBatch(batchId)
  return { storagePath: objectPath, batchId, pipelineResult, batchRow }
}
