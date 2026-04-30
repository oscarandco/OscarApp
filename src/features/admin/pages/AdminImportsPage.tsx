import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react'

import { PageHeader } from '@/components/layout/PageHeader'
import { ImportSalesDataProgress } from '@/features/admin/components/ImportSalesDataProgress'
import {
  guessLocationIdFromFileName,
  isLikelyCsvFile,
  uploadAndTriggerSalesDailySheetsImport,
} from '@/lib/salesDailySheetsImport'
import {
  rpcDeleteAllSalesDailySheetsImportData,
  rpcListActiveLocationsForImport,
  type SalesDailySheetsImportBatchRow,
} from '@/lib/supabaseRpc'

type FlowStatus = 'idle' | 'uploading' | 'processing' | 'done' | 'failed'

/** Finer-grained UI for the Sales Daily Sheets import mutation (frontend only). */
type ImportUiPhase = 'idle' | 'upload' | 'prequeue' | 'queued' | 'processing'

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
  const [importPhase, setImportPhase] = useState<ImportUiPhase>('idle')
  const [liveBatch, setLiveBatch] = useState<SalesDailySheetsImportBatchRow | null>(null)
  const importStartedAtRef = useRef(0)
  const [importStartedAt, setImportStartedAt] = useState(0)
  const [nowTick, setNowTick] = useState(() => Date.now())
  const [completedSnapshot, setCompletedSnapshot] = useState<{
    durationMs: number
    batch: SalesDailySheetsImportBatchRow | null
  } | null>(null)
  /** Keep checklist visible after a failed import until the user starts over. */
  const [importFailedView, setImportFailedView] = useState(false)
  const [importRunKey, setImportRunKey] = useState(0)
  const [activeBatchId, setActiveBatchId] = useState<string | null>(null)
  const [stagingComplete, setStagingComplete] = useState(false)
  const [applyStarted, setApplyStarted] = useState(false)
  const [parseSnapshot, setParseSnapshot] = useState<{
    csvRowsRead: number
    rowsStaged: number
  } | null>(null)

  const { data: locations = [], isLoading: locationsLoading } = useQuery({
    queryKey: ['list-active-locations-import'],
    queryFn: rpcListActiveLocationsForImport,
  })

  useEffect(() => {
    if (!file || locations.length === 0) return
    const guess = guessLocationIdFromFileName(file.name, locations)
    if (guess) setLocationId(guess)
  }, [file, locations])

  const selectedLocationName = useMemo(() => {
    const loc = locations.find((l) => l.id === locationId)
    const n = loc?.name?.trim()
    return n && n.length > 0 ? n : 'Selected location'
  }, [locations, locationId])

  const importMutation = useMutation({
    mutationFn: async (args: { file: File; locationId: string }) => {
      const t0 = Date.now()
      importStartedAtRef.current = t0
      setImportStartedAt(t0)
      setNowTick(t0)
      setCompletedSnapshot(null)
      setImportFailedView(false)
      setImportRunKey((k) => k + 1)
      setActiveBatchId(null)
      setStagingComplete(false)
      setApplyStarted(false)
      setParseSnapshot(null)
      setStatus('uploading')
      setImportPhase('upload')
      setLiveBatch(null)
      setMessage(null)
      return uploadAndTriggerSalesDailySheetsImport(args.file, args.locationId, {
        onUploaded: () => {
          setStatus('processing')
          setImportPhase('prequeue')
        },
        onQueueRegistered: () => {
          setImportPhase('queued')
        },
        onBatchId: (batchId) => {
          setActiveBatchId(batchId)
        },
        onParseProgress: (info) => {
          setParseSnapshot(info)
        },
        onStagingComplete: (info) => {
          setParseSnapshot(info)
          setStagingComplete(true)
        },
        onApplyStart: () => {
          setApplyStarted(true)
        },
        onEdgeAccepted: () => {
          setImportPhase('processing')
        },
        onBatchPoll: (row) => {
          setLiveBatch(row)
        },
      })
    },
    onSuccess: (res) => {
      setStatus('done')
      setImportPhase('idle')
      setImportFailedView(false)
      if (res.batchRow) setLiveBatch(res.batchRow)
      setCompletedSnapshot({
        durationMs: Date.now() - importStartedAtRef.current,
        batch: res.batchRow ?? null,
      })
      setMessage('Import finished successfully.')
      const irPart =
        res.batchRow?.import_result != null
          ? `import_result:\n${summarizePipelineResult(res.batchRow.import_result)}\n\n`
          : ''
      const batchPart = res.batchRow
        ? `Batch status: ${res.batchRow.status ?? '?'}\nrows_staged: ${String(res.batchRow.rows_staged ?? '')}\nrows_loaded: ${String(res.batchRow.rows_loaded ?? '')}\nmessage: ${res.batchRow.message ?? ''}\nerror_message: ${res.batchRow.error_message ?? ''}\n\n${irPart}`
        : ''
      setLastSummary(
        `Storage path: ${res.storagePath}\n\n${batchPart}Queue RPC / pipeline:\n${summarizePipelineResult(res.pipelineResult)}`,
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
      setImportFailedView(true)
      setCompletedSnapshot(null)
      setStagingComplete(false)
      setApplyStarted(false)
      setParseSnapshot(null)
      setMessage(
        err instanceof Error ? err.message : 'Import failed. Check the console or Supabase logs.',
      )
    },
  })

  const resetMutation = useMutation({
    mutationFn: rpcDeleteAllSalesDailySheetsImportData,
    onSuccess: (data) => {
      setMessage(
        `All Sales Daily Sheets import records were removed for every salon. You can run a completely fresh import if you need to.\n\n${summarizePipelineResult(data)}`,
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

  useEffect(() => {
    if (!importMutation.isPending || resetMutation.isPending) return
    const id = window.setInterval(() => setNowTick(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [importMutation.isPending, resetMutation.isPending])

  function onPick(e: React.ChangeEvent<HTMLInputElement>) {
    const f = e.target.files?.[0] ?? null
    setFile(f)
    setMessage(null)
    setLastSummary(null)
    setLiveBatch(null)
    setImportPhase('idle')
    setCompletedSnapshot(null)
    setImportFailedView(false)
    setActiveBatchId(null)
    setStagingComplete(false)
    setApplyStarted(false)
    setParseSnapshot(null)
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
      'Delete all Sales Daily Sheets records that have been imported, for every salon?\n\nThis clears imported data from this feature so you can start completely fresh if needed. Information that came from other systems is not removed. This cannot be undone.\n\nThis option is only for managers and administrators.',
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
        description="Upload your sales daily sheets spreadsheet into the app for one salon at a time. Each upload replaces that salon’s earlier Sales Daily Sheets data and refreshes commission calculations. This form should be used by managers and administrators only."
      />

      <div className="space-y-6">
        <ol className="list-decimal space-y-1 pl-5 text-sm text-slate-600">
          <li>Extract the Sales Daily Sheets report from Kitomba</li>
          <li>Save it to a known location</li>
          <li>
            Click the &apos;Choose File&apos; button below
          </li>
          <li>Select the file you extracted from Kitomba</li>
          <li>Check/Select the location</li>
          <li>
            Click the &apos;Upload and import&apos; button
          </li>
        </ol>

        <div
          role="status"
          className="rounded-lg border border-slate-200 bg-slate-50 px-4 py-3 text-sm text-slate-800"
        >
          <p className="font-medium">One salon at a time</p>
          <p className="mt-1">
            Each upload refreshes commission calculations for the{' '}
            <span className="font-medium">location you select only</span>. Figures that came from
            elsewhere in the app are not removed by this step.
          </p>
        </div>

        <div className="flex flex-col gap-6 lg:flex-row lg:items-start lg:gap-8">
          <div className="min-w-0 flex-1">
        <form
          onSubmit={(e) => void onSubmit(e)}
          className="space-y-4 rounded-lg border border-slate-200 bg-white p-6 shadow-sm"
          aria-labelledby="admin-imports-upload-heading"
        >
          <div>
            <h2
              id="admin-imports-upload-heading"
              className="text-base font-semibold text-slate-900"
            >
              Upload and import
            </h2>
            <p className="mt-1 text-sm text-slate-600">
              Your file is uploaded safely, then processed in this browser window so commission
              calculations can be updated for this salon. Please keep this tab open until it finishes.
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

          <div className="space-y-2">
            <div className="flex flex-wrap items-center gap-3">
              <button
                type="submit"
                disabled={busy || !canSubmit}
                className="rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
                data-testid="admin-imports-submit"
              >
                {importMutation.isPending && !resetMutation.isPending
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

            {(importMutation.isPending && !resetMutation.isPending) ||
            completedSnapshot ||
            importFailedView ? (
              <ImportSalesDataProgress
                importPhase={importPhase}
                importPending={importMutation.isPending && !resetMutation.isPending}
                failed={importFailedView || status === 'failed'}
                errorText={message}
                startedAt={importStartedAt}
                nowTick={nowTick}
                liveBatch={liveBatch}
                activeBatchId={activeBatchId}
                stagingComplete={stagingComplete}
                applyStarted={applyStarted}
                applyFinished={status === 'done'}
                parseSnapshot={parseSnapshot}
                selectedLocationName={selectedLocationName}
                importRunKey={importRunKey}
                completedSnapshot={completedSnapshot}
              />
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
      </form>
          </div>

          <div className="flex w-full shrink-0 flex-col gap-6 lg:sticky lg:top-4 lg:w-72 lg:self-start xl:w-80">
          <aside
            className="w-full rounded-lg border border-red-200 bg-red-50 p-5 shadow-sm"
            aria-labelledby="admin-imports-admin-delete-heading"
          >
            <h2
              id="admin-imports-admin-delete-heading"
              className="text-base font-semibold text-red-900"
            >
              Admin: Delete all records
            </h2>
            <p className="mt-2 text-sm leading-relaxed text-red-950/90">
              Removes every Sales Daily Sheets import stored in the app across{' '}
              <span className="font-medium text-red-950">all salons</span>, so you can load
              everything again from scratch if you ever need a clean slate. Regular uploads for a
              single salon already replace that salon’s data.  You only need to use this function for an all-salon
              fresh start.
            </p>
            <p className="mt-2 text-xs text-red-800/90">Managers and administrators only.</p>
            <button
              type="button"
              disabled={busy || resetMutation.isPending}
              onClick={() => void onResetClick()}
              className="mt-4 w-full rounded-md border border-red-700 bg-red-700 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-red-800 disabled:cursor-not-allowed disabled:opacity-50"
              data-testid="admin-imports-reset-all"
            >
              {resetMutation.isPending ? 'Removing records…' : 'Delete all Sales Daily Sheets records'}
            </button>
          </aside>

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
          </div>
        </div>
      </div>
    </div>
  )
}
