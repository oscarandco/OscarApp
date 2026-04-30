import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { flushSync } from 'react-dom'
import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react'

import { PageHeader } from '@/components/layout/PageHeader'
import { AdminImportsRpcStepProgress } from '@/features/admin/components/AdminImportsRpcStepProgress'
import { ImportSalesDataProgress } from '@/features/admin/components/ImportSalesDataProgress'
import {
  guessLocationIdFromFileName,
  isLikelyCsvFile,
  uploadAndTriggerSalesDailySheetsImport,
} from '@/lib/salesDailySheetsImport'
import {
  rpcDeleteAllSalesDailySheetsImportData,
  rpcListActiveLocationsForImport,
  rpcListSalesDailySheetsRebuildBatches,
  rpcRebuildSalesDailySheetsReportingBatch,
  type DeleteSalesDailySheetsImportDataResult,
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

const DELETE_PROGRESS_STEPS = [
  'Checking delete scope',
  'Deleting generated sales transactions',
  'Deleting raw import rows',
  'Deleting import batches',
  'Deleting staged import records',
  'Refreshing page data',
  'Done',
] as const

function formatAdminCount(n: number): string {
  return n.toLocaleString(undefined, { maximumFractionDigits: 0 })
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
  const [rebuildLocationId, setRebuildLocationId] = useState('')
  const [rebuildPanelOpen, setRebuildPanelOpen] = useState(false)
  const [rebuildDynamicSteps, setRebuildDynamicSteps] = useState<string[]>([
    'Checking existing Sales Daily Sheets batches',
    'Done',
  ])
  const [rebuildActiveStepIndex, setRebuildActiveStepIndex] = useState(0)
  const rebuildActiveStepRef = useRef(0)
  const [rebuildProgFailureAt, setRebuildProgFailureAt] = useState<number | null>(null)
  const [rebuildProgAllComplete, setRebuildProgAllComplete] = useState(false)
  const [rebuildProgFailed, setRebuildProgFailed] = useState(false)
  const [rebuildProgResult, setRebuildProgResult] = useState<string | null>(null)

  const [deleteLocationId, setDeleteLocationId] = useState('')
  const [deletePanelOpen, setDeletePanelOpen] = useState(false)
  const [deleteProgCursor, setDeleteProgCursor] = useState(0)
  const [deleteProgFailureAt, setDeleteProgFailureAt] = useState<number | null>(null)
  const [deleteProgAllComplete, setDeleteProgAllComplete] = useState(false)
  const [deleteProgFailed, setDeleteProgFailed] = useState(false)
  const [deleteProgResult, setDeleteProgResult] = useState<string | null>(null)
  const deleteProgCursorRef = useRef(0)
  const [importRunKey, setImportRunKey] = useState(0)
  const [activeBatchId, setActiveBatchId] = useState<string | null>(null)
  const [stagingComplete, setStagingComplete] = useState(false)
  const [applyStarted, setApplyStarted] = useState(false)
  const [parseSnapshot, setParseSnapshot] = useState<{
    csvRowsRead: number
    rowsStaged: number
  } | null>(null)

  const bumpRebuildStep = (n: number) => {
    rebuildActiveStepRef.current = n
    flushSync(() => setRebuildActiveStepIndex(n))
  }

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

  const deleteScopeSalonLabel = useMemo(() => {
    const loc = locations.find((l) => l.id === deleteLocationId)
    const n = loc?.name?.trim()
    if (n && n.length > 0) return n
    const c = loc?.code?.trim()
    if (c && c.length > 0) return c
    return 'this salon'
  }, [locations, deleteLocationId])

  const rebuildScopeLabel = useMemo(() => {
    if (rebuildLocationId.trim() === '') return 'All locations'
    const loc = locations.find((l) => l.id === rebuildLocationId)
    const n = loc?.name?.trim()
    if (n && n.length > 0) return n
    return loc?.code?.trim() || 'Selected location'
  }, [locations, rebuildLocationId])

  const invalidateSalesRebuildCaches = () => {
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
    void queryClient.invalidateQueries({
      queryKey: ['location-sales-summary-my-sales'],
    })
    void queryClient.invalidateQueries({
      queryKey: ['sales-daily-sheets-data-sources'],
    })
    void queryClient.invalidateQueries({
      queryKey: ['kpi-snapshot-live'],
    })
    void queryClient.invalidateQueries({
      queryKey: ['kpi-stylist-comparisons-live'],
    })
  }

  type RebuildBatchFlowResult =
    | { kind: 'empty'; scopeLabel: string }
    | { kind: 'ok'; scopeLabel: string; batches: number; deleted: number; created: number }

  const rebuildMutation = useMutation({
    mutationFn: async (): Promise<RebuildBatchFlowResult> => {
      const pid = rebuildLocationId.trim() === '' ? null : rebuildLocationId.trim()
      const scope = rebuildScopeLabel

      const batches = await rpcListSalesDailySheetsRebuildBatches({ p_location_id: pid })
      const n = batches.length

      if (n === 0) {
        const emptySteps = [
          'Checking existing Sales Daily Sheets batches',
          'Refreshing page data',
          'Done',
        ]
        flushSync(() => {
          setRebuildDynamicSteps(emptySteps)
          rebuildActiveStepRef.current = 0
          setRebuildActiveStepIndex(0)
        })
        bumpRebuildStep(1)
        invalidateSalesRebuildCaches()
        bumpRebuildStep(2)
        return { kind: 'empty', scopeLabel: scope }
      }

      const stepLabels = [
        'Checking existing Sales Daily Sheets batches',
        ...batches.map(
          (b, i) => `Rebuilding ${b.location_name} batch ${i + 1} of ${n}...`,
        ),
        'Refreshing page data',
        'Done',
      ]
      flushSync(() => {
        setRebuildDynamicSteps(stepLabels)
        rebuildActiveStepRef.current = 0
        setRebuildActiveStepIndex(0)
      })
      bumpRebuildStep(1)

      let totalDel = 0
      let totalCr = 0
      for (let i = 0; i < n; i++) {
        bumpRebuildStep(1 + i)
        try {
          const one = await rpcRebuildSalesDailySheetsReportingBatch(batches[i].batch_id)
          if (one.status !== 'ok') {
            throw new Error(`status ${one.status}`)
          }
          totalDel += one.transactions_deleted
          totalCr += one.transactions_created
        } catch (e) {
          const base = e instanceof Error ? e.message : String(e)
          const b = batches[i]
          throw new Error(
            `Batch ${i + 1} of ${n} (${b.location_name}, file: ${b.source_file_name || 'unknown'}, id: ${b.batch_id}): ${base}`,
          )
        }
      }

      bumpRebuildStep(1 + n)
      invalidateSalesRebuildCaches()
      bumpRebuildStep(2 + n)

      return {
        kind: 'ok',
        scopeLabel: scope,
        batches: n,
        deleted: totalDel,
        created: totalCr,
      }
    },
    onMutate: () => {
      setRebuildPanelOpen(true)
      setRebuildProgFailureAt(null)
      setRebuildProgAllComplete(false)
      setRebuildProgFailed(false)
      setRebuildProgResult(null)
      setRebuildDynamicSteps([
        'Checking existing Sales Daily Sheets batches',
        'Done',
      ])
      rebuildActiveStepRef.current = 0
      setRebuildActiveStepIndex(0)
    },
    onSuccess: (res: RebuildBatchFlowResult) => {
      setRebuildProgFailed(false)
      setRebuildProgFailureAt(null)
      setRebuildProgAllComplete(true)
      if (res.kind === 'empty') {
        setRebuildProgResult(
          `Rebuild complete for ${res.scopeLabel}. 0 batches rebuilt.`,
        )
        return
      }
      setRebuildProgResult(
        `Rebuild complete for ${res.scopeLabel}. ${res.batches} batches rebuilt, ${formatAdminCount(res.deleted)} transactions deleted, ${formatAdminCount(res.created)} transactions created.`,
      )
    },
    onError: (err: unknown) => {
      setRebuildProgFailed(true)
      setRebuildProgAllComplete(false)
      setRebuildProgFailureAt(rebuildActiveStepRef.current)
      setRebuildProgResult(
        `Rebuild failed: ${err instanceof Error ? err.message : String(err)}`,
      )
      console.error('rebuild_sales_daily_sheets batch flow failed', err)
    },
  })

  const resetMutation = useMutation({
    mutationFn: (args: { p_location_id: string | null }) =>
      rpcDeleteAllSalesDailySheetsImportData({ p_location_id: args.p_location_id }),
    onMutate: () => {
      setDeletePanelOpen(true)
      setDeleteProgFailureAt(null)
      setDeleteProgAllComplete(false)
      setDeleteProgFailed(false)
      setDeleteProgResult(null)
      setDeleteProgCursor(0)
    },
    onSuccess: (res: DeleteSalesDailySheetsImportDataResult) => {
      const failed = res.status !== 'ok'
      setDeleteProgFailed(failed)
      if (failed) {
        setDeleteProgAllComplete(false)
        setDeleteProgFailureAt(
          Math.min(deleteProgCursorRef.current, DELETE_PROGRESS_STEPS.length - 2),
        )
        setDeleteProgResult(
          [
            `Delete failed: status ${res.status}`,
            res.message || '',
            `Transactions deleted: ${formatAdminCount(res.transactions_deleted)}`,
            `Raw rows deleted: ${formatAdminCount(res.raw_rows_deleted)}`,
            `Import batches deleted: ${formatAdminCount(res.sales_import_batches_deleted)}`,
            `Staged rows deleted: ${formatAdminCount(res.staged_rows_deleted)}`,
            `Sheet batches deleted: ${formatAdminCount(res.staged_batches_deleted)}`,
          ]
            .filter(Boolean)
            .join('\n'),
        )
        return
      }
      setDeleteProgAllComplete(true)
      setDeleteProgFailureAt(null)
      setDeleteProgResult(
        `Delete complete for ${res.location_name}. ${formatAdminCount(res.transactions_deleted)} transactions deleted, ${formatAdminCount(res.raw_rows_deleted)} raw rows deleted, ${formatAdminCount(res.sales_import_batches_deleted)} import batch(es) deleted, ${formatAdminCount(res.staged_rows_deleted)} staged row(s), ${formatAdminCount(res.staged_batches_deleted)} sheet batch(es).`,
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
      void queryClient.invalidateQueries({
        queryKey: ['location-sales-summary-my-sales'],
      })
      void queryClient.invalidateQueries({
        queryKey: ['sales-daily-sheets-data-sources'],
      })
      void queryClient.invalidateQueries({
        queryKey: ['kpi-snapshot-live'],
      })
      void queryClient.invalidateQueries({
        queryKey: ['kpi-stylist-comparisons-live'],
      })
    },
    onError: (err: unknown) => {
      setDeleteProgFailed(true)
      setDeleteProgAllComplete(false)
      setDeleteProgFailureAt(
        Math.min(deleteProgCursorRef.current, DELETE_PROGRESS_STEPS.length - 2),
      )
      setDeleteProgResult(
        `Delete failed: ${err instanceof Error ? err.message : String(err)}`,
      )
      console.error('delete_all_sales_daily_sheets_import_data failed', err)
    },
  })

  useEffect(() => {
    deleteProgCursorRef.current = deleteProgCursor
  }, [deleteProgCursor])

  useEffect(() => {
    if (!resetMutation.isPending) return
    setDeleteProgCursor(0)
    const id = window.setInterval(() => {
      setDeleteProgCursor((c) => Math.min(c + 1, DELETE_PROGRESS_STEPS.length - 2))
    }, 800)
    return () => window.clearInterval(id)
  }, [resetMutation.isPending])

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

  useEffect(() => {
    if (!importMutation.isPending || resetMutation.isPending || rebuildMutation.isPending)
      return
    const id = window.setInterval(() => setNowTick(Date.now()), 1000)
    return () => window.clearInterval(id)
  }, [importMutation.isPending, resetMutation.isPending, rebuildMutation.isPending])

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
    const allSalons = deleteLocationId.trim() === ''
    const ok = allSalons
      ? window.confirm(
          'This will delete all Sales Daily Sheets records for all salons. Continue?',
        )
      : window.confirm(
          `This will delete Sales Daily Sheets records for ${deleteScopeSalonLabel} only. Continue?`,
        )
    if (!ok) return
    setLastSummary(null)
    resetMutation.mutate({
      p_location_id: allSalons ? null : deleteLocationId.trim(),
    })
  }

  /** Upload/import + delete — does not include rebuild so rebuild stays usable after import completes. */
  const importOrResetBusy =
    status === 'uploading' ||
    status === 'processing' ||
    importMutation.isPending ||
    resetMutation.isPending

  /** Disables all primary actions to avoid overlapping heavy DB work. */
  const pageHeavyBusy =
    importOrResetBusy || rebuildMutation.isPending

  const rebuildControlsDisabled =
    locationsLoading || rebuildMutation.isPending || importOrResetBusy

  const deleteControlsDisabled =
    locationsLoading ||
    resetMutation.isPending ||
    importOrResetBusy ||
    rebuildMutation.isPending

  const canSubmit =
    Boolean(file) &&
    isLikelyCsvFile(file!) &&
    Boolean(locationId) &&
    !locationsLoading

  return (
    <div data-testid="admin-imports-page">
      <PageHeader
        title="Sales Daily Sheets import"
        description="Upload your Sales Daily Sheets spreadsheet into the app for one salon at a time. Each upload replaces that salon's earlier Sales Daily Sheets data for the uploaded date range and refreshes commission calculations."
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
              disabled={pageHeavyBusy}
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
              disabled={pageHeavyBusy || locationsLoading}
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
                disabled={pageHeavyBusy || !canSubmit}
                className="inline-flex rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
                data-testid="admin-imports-submit"
              >
                {importMutation.isPending && !resetMutation.isPending
                  ? 'Uploading...'
                  : 'Upload and import'}
              </button>
              {status !== 'idle' && !importOrResetBusy ? (
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

        <aside
          className="w-full rounded-lg border border-sky-200 bg-sky-50 p-5 shadow-sm"
          aria-labelledby="admin-imports-rebuild-heading"
        >
          <h2
            id="admin-imports-rebuild-heading"
            className="text-base font-semibold text-sky-950"
          >
            Rebuild reporting data
          </h2>
          <div className="mt-2 space-y-2 text-sm leading-relaxed text-sky-950/90">
            <p>
              Rebuild sales transactions and reporting outputs from Sales Daily Sheets data already
              loaded in the app. 
            <br/>
            Use this after staff, product, remuneration, or commission-rule changes.
            <br/>
              This does not upload a new file and does not delete the original imported raw data.
            </p>
          </div>
          <label
            htmlFor="admin-imports-rebuild-location"
            className="mt-4 block text-sm font-medium text-sky-950"
          >
            Location
          </label>
          <select
            id="admin-imports-rebuild-location"
            value={rebuildLocationId}
            onChange={(e) => {
              setRebuildLocationId(e.target.value)
              setRebuildPanelOpen(false)
              setRebuildProgResult(null)
              setRebuildProgFailed(false)
              setRebuildProgAllComplete(false)
              setRebuildProgFailureAt(null)
              setRebuildDynamicSteps([
                'Checking existing Sales Daily Sheets batches',
                'Done',
              ])
              rebuildActiveStepRef.current = 0
              setRebuildActiveStepIndex(0)
            }}
            disabled={rebuildControlsDisabled}
            className="mt-2 block w-full rounded-md border border-sky-200 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-sky-500 focus:outline-none focus:ring-1 focus:ring-sky-500 disabled:opacity-50"
            data-testid="admin-imports-rebuild-location"
          >
            <option value="">All locations</option>
            {locations.map((loc) => (
              <option key={loc.id} value={loc.id}>
                {loc.name} ({loc.code})
              </option>
            ))}
          </select>
          <button
            type="button"
            disabled={rebuildControlsDisabled}
            onClick={() => void rebuildMutation.mutate()}
            className="mt-4 inline-flex rounded-md bg-sky-600 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-sky-700 disabled:cursor-not-allowed disabled:opacity-50"
            data-testid="admin-imports-rebuild-reporting"
          >
            {rebuildMutation.isPending ? 'Rebuilding...' : 'Rebuild data'}
          </button>
          {rebuildPanelOpen ? (
            <AdminImportsRpcStepProgress
              variant="sky"
              steps={rebuildDynamicSteps}
              isRunning={rebuildMutation.isPending}
              isFailed={rebuildProgFailed || rebuildMutation.isError}
              failureAt={rebuildProgFailureAt}
              cursor={rebuildActiveStepIndex}
              allComplete={rebuildProgAllComplete}
              resultLine={rebuildProgResult}
            />
          ) : null}
        </aside>

        <aside
          className="w-full rounded-lg border border-red-200 bg-red-50 p-5 shadow-sm"
          aria-labelledby="admin-imports-admin-delete-heading"
        >
          <h2
            id="admin-imports-admin-delete-heading"
            className="text-base font-semibold text-red-900"
          >
            Delete all records
          </h2>
          <p className="mt-2 text-sm leading-relaxed text-red-950/90">
            {deleteLocationId.trim() === '' ? (
              <>
                <span className="font-medium text-red-950">All locations</span> is selected: this
                removes every Sales Daily Sheets import stored in the app across{' '}
                <span className="font-medium text-red-950">all locations</span>. <br/>Use only for a full
                reset - this cannot be undone.
              </>
            ) : (
              <>
                Only <span className="font-medium text-red-950">{deleteScopeSalonLabel}</span> is
                selected: Sales Daily Sheets data for{' '}
                <span className="font-medium text-red-950">that salon only</span> will be removed.
                <br/>Other salons are not affected - this cannot be undone.
              </>
            )}
          </p>
          <label
            htmlFor="admin-imports-delete-location"
            className="mt-4 block text-sm font-medium text-red-950"
          >
            Location
          </label>
          <select
            id="admin-imports-delete-location"
            value={deleteLocationId}
            onChange={(e) => {
              setDeleteLocationId(e.target.value)
              setDeletePanelOpen(false)
              setDeleteProgResult(null)
              setDeleteProgFailed(false)
              setDeleteProgAllComplete(false)
              setDeleteProgFailureAt(null)
            }}
            disabled={deleteControlsDisabled}
            className="mt-2 block w-full rounded-md border border-red-200 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-red-600 focus:outline-none focus:ring-1 focus:ring-red-500 disabled:opacity-50"
            data-testid="admin-imports-delete-location"
          >
            <option value="">All locations</option>
            {locations.map((loc) => (
              <option key={loc.id} value={loc.id}>
                {loc.name} ({loc.code})
              </option>
            ))}
          </select>
          <button
            type="button"
            disabled={pageHeavyBusy}
            onClick={() => void onResetClick()}
            className="mt-4 inline-flex rounded-md bg-red-700 px-4 py-2 text-sm font-medium text-white shadow-sm hover:bg-red-800 disabled:cursor-not-allowed disabled:opacity-50"
            data-testid="admin-imports-reset-all"
          >
            {resetMutation.isPending ? 'Deleting...' : 'Delete all records'}
          </button>
          {deletePanelOpen ? (
            <AdminImportsRpcStepProgress
              variant="red"
              steps={DELETE_PROGRESS_STEPS}
              isRunning={resetMutation.isPending}
              isFailed={deleteProgFailed || resetMutation.isError}
              failureAt={deleteProgFailureAt}
              cursor={deleteProgCursor}
              allComplete={deleteProgAllComplete}
              resultLine={deleteProgResult}
            />
          ) : null}
        </aside>
      </div>
    </div>
  )
}
