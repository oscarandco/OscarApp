import {
  getSalesDailySheetsBucket,
  getSalesDailySheetsPathPrefix,
} from '@/lib/env'
import { requireSupabaseClient } from '@/lib/supabase'
import { rpcTriggerSalesDailySheetsImport } from '@/lib/supabaseRpc'

function sanitizeFileName(name: string): string {
  const base = name.split(/[/\\]/).pop() ?? 'upload.csv'
  return base.replace(/[^a-zA-Z0-9._-]+/g, '_').slice(0, 200) || 'upload.csv'
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
  options?: { onUploaded?: (objectPath: string) => void },
): Promise<{ storagePath: string; pipelineResult: unknown }> {
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

  const pipelineResult = await rpcTriggerSalesDailySheetsImport(objectPath)
  return { storagePath: objectPath, pipelineResult }
}
