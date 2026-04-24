import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState, type FormEvent } from 'react'

import { PageHeader } from '@/components/layout/PageHeader'
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

type StepVisual = 'pending' | 'running' | 'done' | 'failed'

function formatDurationShort(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return '—'
  const s = Math.floor(ms / 1000)
  const m = Math.floor(s / 60)
  const sec = s % 60
  if (m <= 0) return `${sec}s`
  return `${m}m ${sec}s`
}

function StepRow({
  label,
  hint,
  state,
  sub,
}: {
  label: string
  hint?: string
  state: StepVisual
  sub?: string
}) {
  return (
    <li className="flex gap-2 text-sm">
      <span className="mt-0.5 w-5 shrink-0 text-center font-medium" aria-hidden>
        {state === 'done'
          ? '✓'
          : state === 'failed'
            ? '✗'
            : state === 'running'
              ? '…'
              : '○'}
      </span>
      <div className="min-w-0 flex-1">
        <p
          className={
            state === 'running'
              ? 'font-semibold text-violet-900'
              : state === 'failed'
                ? 'font-medium text-red-800'
                : state === 'done'
                  ? 'text-slate-700'
                  : 'text-slate-500'
          }
        >
          {label}
          {hint ? (
            <span className="ml-1 text-xs font-normal text-slate-500">({hint})</span>
          ) : null}
        </p>
        {sub ? <p className="mt-0.5 text-xs text-slate-500">{sub}</p> : null}
      </div>
    </li>
  )
}

function ImportProgressChecklist(props: {
  importPhase: ImportUiPhase
  liveBatch: SalesDailySheetsImportBatchRow | null
  importPending: boolean
  failed: boolean
  errorText: string | null
  startedAt: number
  nowTick: number
  /** After a successful run, show all steps complete with final duration. */
  completedSnapshot: { durationMs: number; batch: SalesDailySheetsImportBatchRow | null } | null
}) {
  const {
    importPhase,
    liveBatch,
    importPending,
    failed,
    errorText,
    startedAt,
    nowTick,
    completedSnapshot,
  } = props

  const batchStatus = (liveBatch?.status ?? '').toLowerCase()
  const totalMs = completedSnapshot
    ? completedSnapshot.durationMs
    : nowTick - startedAt

  if (completedSnapshot) {
    const b = completedSnapshot.batch
    return (
      <div
        className="rounded-lg border border-emerald-200 bg-gradient-to-b from-emerald-50/90 to-white px-4 py-3 shadow-sm"
        role="status"
        data-testid="admin-imports-progress-complete"
      >
        <p className="text-sm font-semibold text-emerald-900">
          Finished in {formatDurationShort(completedSnapshot.durationMs)}
        </p>
        <p className="mt-1 text-xs text-emerald-800/90">
          Everything completed successfully. You can review the details under “Latest result” below.
        </p>
        <ol className="mt-3 list-none space-y-1.5 pl-0 text-sm text-emerald-900/90">
          <li>✓ File uploaded</li>
          <li>✓ Import job created</li>
          <li>✓ Import run started</li>
          <li>✓ Spreadsheet read</li>
          <li>✓ Rows saved{b?.rows_staged != null ? ` (${b.rows_staged} rows)` : ''}</li>
          <li>✓ Commission calculations updated{b?.rows_loaded != null ? ` (${b.rows_loaded} rows)` : ''}</li>
          <li>✓ All done</li>
        </ol>
      </div>
    )
  }

  const sUpload: StepVisual =
    importPhase === 'upload' ? 'running' : importPending || importPhase !== 'idle' ? 'done' : 'pending'

  const sQueue: StepVisual =
    importPhase === 'upload'
      ? 'pending'
      : importPhase === 'prequeue'
        ? failed
          ? 'failed'
          : 'running'
        : 'done'

  const sEdge: StepVisual =
    failed && importPhase === 'queued'
      ? 'failed'
      : importPhase === 'upload' || importPhase === 'prequeue'
        ? 'pending'
        : importPhase === 'queued'
          ? 'running'
          : 'done'

  const serverActive =
    importPhase === 'processing' ||
    batchStatus === 'processing' ||
    batchStatus === 'queued'

  const serverDone = batchStatus === 'completed'
  const serverFailed = batchStatus === 'failed' || failed

  const sParse: StepVisual = serverFailed
    ? 'failed'
    : serverDone
      ? 'done'
      : serverActive
        ? 'running'
        : 'pending'

  const sInsert: StepVisual = serverFailed
    ? 'failed'
    : serverDone
      ? 'done'
      : serverActive
        ? 'running'
        : 'pending'

  const sPayroll: StepVisual = serverFailed
    ? 'failed'
    : serverDone
      ? 'done'
      : serverActive
        ? 'running'
        : 'pending'

  const sDone: StepVisual = serverFailed ? 'failed' : serverDone ? 'done' : 'pending'

  return (
    <div
      className="rounded-lg border border-violet-200 bg-gradient-to-b from-violet-50/90 to-white px-4 py-3 shadow-sm"
      role="status"
      aria-live="polite"
      data-testid="admin-imports-progress"
    >
      <div className="flex flex-wrap items-baseline justify-between gap-2 border-b border-violet-100 pb-2">
        <p className="text-sm font-semibold text-slate-900">Import progress</p>
        <p className="font-mono text-xs text-slate-600">
          Time so far: <span className="text-slate-800">{formatDurationShort(totalMs)}</span>
        </p>
      </div>
      <p className="mt-2 text-xs leading-relaxed text-slate-600">
        Big files can take a few minutes—your data is read, saved line by line, then fed into commission
        calculations. The work runs in this browser window, so please keep this tab open until you see
        “Finished”. There isn’t a percent complete; these steps and any row counts we receive are the best
        guide while the import runs.
      </p>
      <ol className="mt-3 list-none space-y-2.5 pl-0">
        <StepRow
          label="Uploading file"
          state={sUpload}
          sub={sUpload === 'running' ? 'Sending your spreadsheet securely…' : undefined}
        />
        <StepRow
          label="Creating your import job"
          state={sQueue}
          sub={
            sQueue === 'running'
              ? 'Setting up your import and checking the file…'
              : undefined
          }
        />
        <StepRow
          label="Import started"
          state={sEdge}
          sub={
            sEdge === 'running'
              ? 'Preparing the import in this browser window — please keep this tab open…'
              : undefined
          }
        />
        <StepRow
          label="Reading your spreadsheet"
          hint="in progress with steps below"
          state={sParse}
          sub={
            serverActive
              ? 'Your CSV is being read and prepared for the next steps—large files stay here longer.'
              : undefined
          }
        />
        <StepRow
          label="Saving each row from your file"
          hint="in progress with steps above"
          state={sInsert}
          sub={
            liveBatch?.rows_staged != null
              ? `Rows saved so far: ${liveBatch.rows_staged}`
              : serverActive
                ? 'Row totals usually appear when the import finishes.'
                : undefined
          }
        />
        <StepRow
          label="Updating commission calculations"
          hint="in progress with steps above"
          state={sPayroll}
          sub={
            liveBatch?.rows_loaded != null
              ? `Rows included in calculations: ${liveBatch.rows_loaded}`
              : serverActive
                ? 'Turning your saved rows into commission figures for this salon.'
                : undefined
          }
        />
        <StepRow
          label="All done"
          state={sDone}
          sub={
            liveBatch?.message && (serverDone || serverFailed)
              ? liveBatch.message
              : undefined
          }
        />
      </ol>
      {liveBatch?.error_message && serverFailed ? (
        <p className="mt-3 rounded border border-red-200 bg-red-50/80 px-2 py-1.5 text-xs text-red-900">
          <span className="font-medium">Something went wrong: </span>
          {liveBatch.error_message}
        </p>
      ) : null}
      {errorText && failed && !liveBatch?.error_message ? (
        <p className="mt-3 rounded border border-red-200 bg-red-50/80 px-2 py-1.5 text-xs text-red-900">
          {errorText}
        </p>
      ) : null}
    </div>
  )
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
      const t0 = Date.now()
      importStartedAtRef.current = t0
      setImportStartedAt(t0)
      setNowTick(t0)
      setCompletedSnapshot(null)
      setImportFailedView(false)
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
      const batchPart = res.batchRow
        ? `Batch status: ${res.batchRow.status ?? '?'}\nrows_staged: ${String(res.batchRow.rows_staged ?? '')}\nrows_loaded: ${String(res.batchRow.rows_loaded ?? '')}\nmessage: ${res.batchRow.message ?? ''}\nerror_message: ${res.batchRow.error_message ?? ''}\n\n`
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
              <ImportProgressChecklist
                importPhase={importPhase}
                liveBatch={liveBatch}
                importPending={importMutation.isPending && !resetMutation.isPending}
                failed={importFailedView || status === 'failed'}
                errorText={message}
                startedAt={importStartedAt}
                nowTick={nowTick}
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
