import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useState, type FormEvent } from 'react'

import { PageHeader } from '@/components/layout/PageHeader'
import {
  guessLocationIdFromFileName,
  isLikelyCsvFile,
  uploadAndTriggerSalesDailySheetsImport,
} from '@/lib/salesDailySheetsImport'
import {
  rpcDeleteAllSalesDailySheetsImportData,
  rpcListActiveLocationsForImport,
} from '@/lib/supabaseRpc'

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
  const [locationId, setLocationId] = useState('')
  const [status, setStatus] = useState<FlowStatus>('idle')
  const [message, setMessage] = useState<string | null>(null)
  const [lastSummary, setLastSummary] = useState<string | null>(null)

  const { data: locations = [], isLoading: locationsLoading } = useQuery({
    queryKey: ['list-active-locations-import'],
    queryFn: rpcListActiveLocationsForImport,
  })

  useEffect(() => {
    if (!file || locations.length === 0) return
    const guess = guessLocationIdFromFileName(file.name, locations)
    if (guess) setLocationId(guess)
  }, [file, locations])

  const importMutation = useMutation({
    mutationFn: async (args: { file: File; locationId: string }) => {
      setStatus('uploading')
      setMessage('Uploading CSV to storage…')
      return uploadAndTriggerSalesDailySheetsImport(args.file, args.locationId, {
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

  const resetMutation = useMutation({
    mutationFn: rpcDeleteAllSalesDailySheetsImportData,
    onSuccess: (data) => {
      setMessage(
        `All Sales Daily Sheets import data was removed.\n\n${summarizePipelineResult(data)}`,
      )
      setStatus('done')
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
        err instanceof Error ? err.message : 'Reset failed. Check the console or Supabase logs.',
      )
    },
  })

  function onPick(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0] ?? null
    setFile(f)
    setMessage(null)
    setLastSummary(null)
    if (!f) {
      setLocationId('')
    }
    if (status === 'done' || status === 'failed') setStatus('idle')
  }

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    if (!file || !isLikelyCsvFile(file)) {
      setStatus('failed')
      setMessage('Choose a .csv file.')
      return
    }
    if (!locationId) {
      setStatus('failed')
      setMessage('Select a location.')
      return
    }
    setLastSummary(null)
    importMutation.mutate({ file, locationId })
  }

  function onResetClick() {
    const ok = window.confirm(
      'Delete ALL Sales Daily Sheets import data? This removes staged rows, import batches, raw rows, and transactions created from Sales Daily Sheets payroll imports. This cannot be undone.',
    )
    if (!ok) return
    setLastSummary(null)
    setMessage(null)
    resetMutation.mutate()
  }

  const busy =
    status === 'uploading' ||
    status === 'processing' ||
    importMutation.isPending ||
    resetMutation.isPending

  const canSubmit =
    Boolean(file) &&
    isLikelyCsvFile(file!) &&
    Boolean(locationId) &&
    !locationsLoading

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
            htmlFor="sales-import-location"
            className="block text-sm font-medium text-slate-700"
          >
            Location <span className="text-red-600">*</span>
          </label>
          <select
            id="sales-import-location"
            required
            value={locationId}
            onChange={(e) => setLocationId(e.target.value)}
            disabled={busy || locationsLoading}
            className="mt-2 block w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500 disabled:opacity-50"
            data-testid="admin-imports-location"
          >
            <option value="">
              {locationsLoading ? 'Loading locations…' : 'Select location…'}
            </option>
            {locations.map((loc) => (
              <option key={loc.id} value={loc.id}>
                {loc.name} ({loc.code})
              </option>
            ))}
          </select>
          <p className="mt-1 text-xs text-slate-500">
            Required. Filenames containing &quot;orewa&quot; or &quot;takapuna&quot; preselect the
            matching salon when you choose a file.
          </p>
        </div>

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
            disabled={busy || !canSubmit}
            className="rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
            data-testid="admin-imports-submit"
          >
            {busy && (status === 'uploading' || importMutation.isPending)
              ? 'Working…'
              : 'Upload and import'}
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
              (status === 'failed'
                ? 'text-sm text-red-700'
                : 'text-sm text-slate-700') + ' whitespace-pre-wrap'
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

      <div className="mt-8 max-w-xl rounded-lg border border-red-200 bg-red-50/50 p-6">
        <h2 className="text-sm font-semibold text-red-900">Danger zone</h2>
        <p className="mt-1 text-sm text-red-800/90">
          Remove every Sales Daily Sheets staged row, sheet import batch, payroll raw row, and
          transaction created from Sales Daily Sheets imports. Use before a full reload.
        </p>
        <button
          type="button"
          disabled={busy || resetMutation.isPending}
          onClick={() => void onResetClick()}
          className="mt-4 rounded-md border border-red-300 bg-white px-4 py-2 text-sm font-medium text-red-800 hover:bg-red-100 disabled:cursor-not-allowed disabled:opacity-50"
          data-testid="admin-imports-reset-all"
        >
          {resetMutation.isPending ? 'Deleting…' : 'Delete all imported records'}
        </button>
      </div>
    </div>
  )
}
