import {
  getSalesDailySheetsBucket,
  getSalesDailySheetsPathPrefix,
} from '@/lib/env'
import { requireSupabaseClient } from '@/lib/supabase'
import type { ImportLocationRow } from '@/lib/supabaseRpc'
import {
  fetchSalesDailySheetsImportBatch,
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

/**
 * Upload CSV to the configured bucket, queue a batch via RPC, run the Edge import, then poll the batch row.
 */
export async function uploadAndTriggerSalesDailySheetsImport(
  file: File,
  locationId: string,
  options?: {
    onUploaded?: (objectPath: string) => void
    /** After the queue RPC returns a queued batch (before Edge invoke). */
    onQueueRegistered?: (batchId: string) => void
    /** After Edge accepts the request (202); batch work runs in the background. */
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

    // Edge returns 202 quickly; heavy work runs in EdgeRuntime.waitUntil — do not rely on a long invoke.
    const { data: fnData, error: fnError } = await client.functions.invoke(
      'sales-daily-sheets-import',
      {
        body: {
          batch_id: batchId,
          storage_path: objectPath,
          location_id: locationId,
        },
      },
    )

    if (fnError) {
      const msg =
        fnError instanceof Error
          ? fnError.message
          : typeof fnError === 'object' &&
              fnError !== null &&
              'message' in fnError &&
              typeof (fnError as { message: unknown }).message === 'string'
            ? (fnError as { message: string }).message
            : String(fnError)
      throw new Error(msg)
    }

    if (isRecord(fnData) && fnData.ok === false) {
      const errMsg =
        typeof fnData.error === 'string'
          ? fnData.error
          : 'Edge import failed'
      throw new Error(errMsg)
    }

    options?.onEdgeAccepted?.()

    const batchRow = await pollSalesDailySheetsBatchUntilTerminal(batchId, {
      maxMs: 15 * 60_000,
      intervalMs: 1500,
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
