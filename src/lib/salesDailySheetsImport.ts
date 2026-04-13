import {
  getSalesDailySheetsBucket,
  getSalesDailySheetsPathPrefix,
} from '@/lib/env'
import { requireSupabaseClient } from '@/lib/supabase'
import type { ImportLocationRow } from '@/lib/supabaseRpc'
import { rpcTriggerSalesDailySheetsImport } from '@/lib/supabaseRpc'

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

/**
 * Upload CSV to the configured bucket, then invoke the import RPC (server-side processing).
 * `onUploaded` runs after Storage succeeds, before the RPC (for UI progress).
 */
export async function uploadAndTriggerSalesDailySheetsImport(
  file: File,
  locationId: string,
  options?: { onUploaded?: (objectPath: string) => void },
): Promise<{ storagePath: string; pipelineResult: unknown }> {
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
  return { storagePath: objectPath, pipelineResult }
}
