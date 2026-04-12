import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'

import { PageHeader } from '@/components/layout/PageHeader'
import {
  isLikelyCsvFile,
  uploadAndTriggerSalesDailySheetsImport,
} from '@/lib/salesDailySheetsImport'

type FlowStatus = 'idle' | 'uploading' | 'processing' | 'done' | 'failed'

function summarizePipelineResult(data: unknown): string {
  if (data == null) return 'Import completed (no details returned).'
  if (typeof data === 'string') return data
  try {
    return JSON.stringify(data, null, 2)
  } catch {
    return String(data)
  }
}

export function AdminImportsPage() {
  const queryClient = useQueryClient()
  const [file, setFile] = useState<File | null>(null)
  const [status, setStatus] = useState<FlowStatus>('idle')
  const [message, setMessage] = useState<string | null>(null)
  const [lastSummary, setLastSummary] = useState<string | null>(null)

  const importMutation = useMutation({
    mutationFn: async (f: File) => {
      setStatus('uploading')
      setMessage('Uploading CSV to storage…')
      return uploadAndTriggerSalesDailySheetsImport(f, {
        onUploaded: () => {
          setStatus('processing')
          setMessage('Running import on the server…')
        },
      })
    },
    onSuccess: (res) => {
      setStatus('done')
      setMessage('Import finished successfully.')
      setLastSummary(
        `Storage path: ${res.storagePath}\n\n${summarizePipelineResult(res.pipelineResult)}`,
      )
      void queryClient.invalidateQueries({
        queryKey: ['my-commission-summary-weekly'],
      })
      void queryClient.invalidateQueries({
        queryKey: ['my-commission-lines-weekly'],
      })
      void queryClient.invalidateQueries({
        queryKey: ['admin-payroll-summary-weekly'],
      })
      void queryClient.invalidateQueries({
        queryKey: ['admin-payroll-lines-weekly'],
      })
    },
    onError: (err: unknown) => {
      setStatus('failed')
      setMessage(
        err instanceof Error ? err.message : 'Import failed. Check the console or Supabase logs.',
      )
    },
  })

  function onPick(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0] ?? null
    setFile(f)
    setMessage(null)
    setLastSummary(null)
    if (status === 'done' || status === 'failed') setStatus('idle')
  }

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (!file || !isLikelyCsvFile(file)) {
      setStatus('failed')
      setMessage('Choose a .csv file.')
      return
    }
    setLastSummary(null)
    importMutation.mutate(file)
  }

  const busy = status === 'uploading' || status === 'processing' || importMutation.isPending

  return (
    <div data-testid="admin-imports-page">
      <PageHeader
        title="Sales Daily Sheets import"
        description="Upload a Sales Daily Sheets CSV: the file is stored in Supabase Storage, then the import pipeline runs on the server (Edge Function or SQL hook). Manager, admin, and superadmin only."
      />

      <form
        onSubmit={(e) => void onSubmit(e)}
        className="max-w-xl space-y-4 rounded-lg border border-slate-200 bg-white p-6 shadow-sm"
      >
        <div>
          <label
            htmlFor="sales-csv-input"
            className="block text-sm font-medium text-slate-700"
          >
            CSV file
          </label>
          <input
            id="sales-csv-input"
            type="file"
            accept=".csv,text/csv"
            className="mt-2 block w-full text-sm text-slate-600 file:mr-4 file:rounded-md file:border-0 file:bg-violet-50 file:px-4 file:py-2 file:text-sm file:font-medium file:text-violet-900 hover:file:bg-violet-100"
            disabled={busy}
            onChange={onPick}
            data-testid="admin-imports-file"
          />
          <p className="mt-1 text-xs text-slate-500">
            {file ? (
              <span className="font-mono">{file.name}</span>
            ) : (
              'No file selected'
            )}
          </p>
        </div>

        <div className="flex flex-wrap items-center gap-3">
          <button
            type="submit"
            disabled={busy || !file || !isLikelyCsvFile(file)}
            className="rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
            data-testid="admin-imports-submit"
          >
            {busy ? 'Working…' : 'Upload and import'}
          </button>
          {status !== 'idle' && !busy ? (
            <span className="text-sm text-slate-600" data-testid="admin-imports-phase">
              {status === 'done'
                ? 'Done'
                : status === 'failed'
                  ? 'Failed'
                  : null}
            </span>
          ) : null}
        </div>

        {message ? (
          <p
            className={
              status === 'failed'
                ? 'text-sm text-red-700'
                : 'text-sm text-slate-700'
            }
            data-testid="admin-imports-message"
          >
            {message}
          </p>
        ) : null}

        {busy ? (
          <p className="text-xs text-slate-500">
            {status === 'uploading' || importMutation.isPending
              ? 'Step 1: uploading to Supabase Storage…'
              : 'Step 2: server import (RPC)…'}
          </p>
        ) : null}

        {lastSummary ? (
          <div className="rounded-md border border-slate-100 bg-slate-50 p-3">
            <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">
              Latest result
            </p>
            <pre className="mt-2 max-h-48 overflow-auto whitespace-pre-wrap break-words text-xs text-slate-800">
              {lastSummary}
            </pre>
          </div>
        ) : null}
      </form>
    </div>
  )
}
