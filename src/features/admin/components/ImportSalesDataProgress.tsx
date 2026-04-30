import { useEffect, useMemo, useState } from 'react'

import type {
  SalesDailySheetsImportBatchRow,
  SalesDailySheetsImportResult,
} from '@/lib/supabaseRpc'

type ImportUiPhase = 'idle' | 'upload' | 'prequeue' | 'queued' | 'processing'

type StepVisual = 'pending' | 'running' | 'done' | 'failed'

const STEP_MS = 580
const STEP_COUNT = 9

const STEP_LABELS: readonly string[] = [
  'File uploaded',
  'Import job created',
  'Import started',
  'CSV rows read',
  'CSV rows staged',
  'Existing records replaced for selected salon/date range',
  'Sales transactions rebuilt',
  'Reporting refreshed',
  'All done',
]

function formatDurationShort(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return '—'
  const s = Math.floor(ms / 1000)
  const m = Math.floor(s / 60)
  const sec = s % 60
  if (m <= 0) return `${sec}s`
  return `${m}m ${sec}s`
}

function formatInt(n: number): string {
  return new Intl.NumberFormat(undefined, { maximumFractionDigits: 0 }).format(n)
}

function toFiniteInt(v: unknown): number | null {
  if (v == null) return null
  if (typeof v === 'number' && Number.isFinite(v)) return Math.round(v)
  if (typeof v === 'string') {
    const n = Number(v)
    return Number.isFinite(n) ? Math.round(n) : null
  }
  return null
}

export function normalizeImportResult(
  raw: unknown,
): SalesDailySheetsImportResult | null {
  if (raw == null || typeof raw !== 'object') return null
  const o = raw as Record<string, unknown>
  const pick = (k: string) => toFiniteInt(o[k])
  return {
    selected_location_name:
      typeof o.selected_location_name === 'string'
        ? o.selected_location_name
        : null,
    date_range_start:
      typeof o.date_range_start === 'string' ? o.date_range_start : null,
    date_range_end:
      typeof o.date_range_end === 'string' ? o.date_range_end : null,
    csv_rows_read: pick('csv_rows_read'),
    csv_rows_staged: pick('csv_rows_staged'),
    existing_rows_before_import: pick('existing_rows_before_import'),
    existing_rows_replaced: pick('existing_rows_replaced'),
    existing_rows_unchanged: pick('existing_rows_unchanged'),
    rows_loaded: pick('rows_loaded'),
    sales_transactions_created: pick('sales_transactions_created'),
  }
}

function useSequentialStepReveal(actualDone: number, resetKey: number) {
  const [shown, setShown] = useState(0)

  useEffect(() => {
    setShown(0)
  }, [resetKey])

  useEffect(() => {
    const capped = Math.min(Math.max(actualDone, 0), STEP_COUNT)
    if (capped <= shown) return
    const t = window.setTimeout(() => {
      setShown((s) => Math.min(s + 1, capped))
    }, STEP_MS)
    return () => clearTimeout(t)
  }, [actualDone, shown, resetKey])

  return Math.min(shown, STEP_COUNT)
}

function formatRangeLabel(isoStart: string | null, isoEnd: string | null): string | null {
  if (!isoStart || !isoEnd) return null
  const d0 = new Date(`${isoStart}T12:00:00`)
  const d1 = new Date(`${isoEnd}T12:00:00`)
  if (Number.isNaN(d0.getTime()) || Number.isNaN(d1.getTime())) {
    return `${isoStart} to ${isoEnd}`
  }
  const fmt = (d: Date) =>
    d.toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })
  return `${fmt(d0)} to ${fmt(d1)}`
}

function buildSuccessSummary(ir: SalesDailySheetsImportResult | null): string {
  const loc =
    ir?.selected_location_name != null && String(ir.selected_location_name).trim() !== ''
      ? String(ir.selected_location_name).trim()
      : 'Selected salon'
  const range = formatRangeLabel(ir?.date_range_start ?? null, ir?.date_range_end ?? null)
  if (range) {
    return `${loc} data from ${range} was replaced successfully. Data outside that date range was left unchanged.`
  }
  return `${loc} data was replaced successfully for the uploaded date range. Data outside that range was left unchanged.`
}

function buildCompletedStepDetails(
  ir: SalesDailySheetsImportResult | null,
  _locNameFallback: string,
): (string | null)[] {
  const out: (string | null)[] = Array(9).fill(null)

  const csvRead = ir?.csv_rows_read
  out[3] = csvRead != null ? `${formatInt(csvRead)}` : null

  const staged = ir?.csv_rows_staged
  out[4] = staged != null ? `${formatInt(staged)}` : null

  const stc = ir?.sales_transactions_created ?? ir?.rows_loaded
  out[6] = stc != null ? `${formatInt(stc)}` : null

  return out
}

export function ImportSalesDataProgress(props: {
  importPhase: ImportUiPhase
  importPending: boolean
  failed: boolean
  errorText: string | null
  startedAt: number
  nowTick: number
  liveBatch: SalesDailySheetsImportBatchRow | null
  activeBatchId: string | null
  stagingComplete: boolean
  applyStarted: boolean
  applyFinished: boolean
  parseSnapshot: { csvRowsRead: number; rowsStaged: number } | null
  selectedLocationName: string
  /** Increment when a new import starts (resets sequential tick animation). */
  importRunKey: number
  completedSnapshot: { durationMs: number; batch: SalesDailySheetsImportBatchRow | null } | null
}) {
  const {
    importPhase,
    importPending,
    failed,
    errorText,
    startedAt,
    nowTick,
    liveBatch,
    activeBatchId,
    stagingComplete,
    applyStarted,
    applyFinished,
    parseSnapshot,
    selectedLocationName,
    importRunKey,
    completedSnapshot,
  } = props

  const batchStatus = (liveBatch?.status ?? '').toLowerCase()
  const serverFailed = batchStatus === 'failed' || failed

  const uploaded = importPhase !== 'idle' || Boolean(completedSnapshot)
  const jobCreated = Boolean(activeBatchId || liveBatch?.id || completedSnapshot)
  const importStarted =
    importPhase === 'queued' ||
    importPhase === 'processing' ||
    batchStatus === 'queued' ||
    batchStatus === 'processing' ||
    Boolean(completedSnapshot)
  const csvReadDone = stagingComplete || Boolean(completedSnapshot)
  const stagedDone = stagingComplete || Boolean(completedSnapshot)

  const actualDoneCount = useMemo(() => {
    if (serverFailed) {
      let n = 0
      if (uploaded) n++
      if (jobCreated) n++
      if (importStarted) n++
      if (csvReadDone) n++
      if (stagedDone) n++
      return Math.min(n, STEP_COUNT)
    }
    let c = 0
    if (uploaded) c++
    else return c
    if (jobCreated) c++
    else return c
    if (importStarted) c++
    else return c
    if (csvReadDone) c++
    else return c
    if (stagedDone) c++
    else return c
    if (applyFinished) return STEP_COUNT
    if (applyStarted) return 5
    return c
  }, [
    serverFailed,
    uploaded,
    jobCreated,
    importStarted,
    csvReadDone,
    stagedDone,
    applyStarted,
    applyFinished,
  ])

  const visualDone = useSequentialStepReveal(actualDoneCount, importRunKey)

  const totalMs = completedSnapshot
    ? completedSnapshot.durationMs
    : nowTick - startedAt

  if (completedSnapshot && !serverFailed) {
    const b = completedSnapshot.batch
    const ir = normalizeImportResult(b?.import_result ?? null)
    const details = buildCompletedStepDetails(ir, selectedLocationName)
    const summary = buildSuccessSummary(ir)

    return (
      <div
        className="rounded-lg border border-emerald-200 bg-gradient-to-b from-emerald-50/90 to-white px-4 py-3 shadow-sm"
        role="status"
        data-testid="admin-imports-progress-complete"
      >
        <p className="text-sm font-semibold text-emerald-900">
          Finished in {formatDurationShort(completedSnapshot.durationMs)}
        </p>
        <p className="mt-2 text-sm leading-relaxed text-emerald-950/90">{summary}</p>
        <ol className="mt-3 list-none space-y-1.5 pl-0 text-sm text-emerald-900/90">
          {STEP_LABELS.map((label, i) => {
            const d = details[i]
            if (i <= 2) {
              return (
                <li key={label}>
                  ✓ {label}
                </li>
              )
            }
            if (i === 3) {
              return (
                <li key={label}>
                  ✓ {label}
                  {d ? `: ${d}` : ''}
                </li>
              )
            }
            if (i === 4) {
              return (
                <li key={label}>
                  ✓ {label}
                  {d ? `: ${d}` : ''}
                </li>
              )
            }
            if (i === 5) {
              const loc =
                ir?.selected_location_name != null &&
                String(ir.selected_location_name).trim() !== ''
                  ? String(ir.selected_location_name).trim()
                  : selectedLocationName
              const rep = ir?.existing_rows_replaced
              const before = ir?.existing_rows_before_import
              const unch = ir?.existing_rows_unchanged
              const showUnchangedExact =
                before != null &&
                rep != null &&
                unch != null &&
                unch === before - rep
              return (
                <li key={label}>
                  <p>✓ {label}</p>
                  {rep != null ? (
                    <p className="mt-1 pl-5 text-sm">
                      Existing {loc} records replaced: {formatInt(rep)}
                    </p>
                  ) : (
                    <p className="mt-1 pl-5 text-sm text-emerald-900/85">
                      Prior Sales Daily Sheets rows for {loc} in the uploaded date range were
                      replaced.
                    </p>
                  )}
                  {showUnchangedExact ? (
                    <p className="mt-0.5 pl-5 text-sm">
                      Existing {loc} records unchanged: {formatInt(unch)}
                    </p>
                  ) : (
                    <p className="mt-0.5 pl-5 text-xs text-emerald-900/80">
                      Existing records outside this date range were left unchanged.
                    </p>
                  )}
                </li>
              )
            }
            if (i === 6) {
              return (
                <li key={label}>
                  ✓ {label}
                  {d ? `: ${d}` : ''}
                </li>
              )
            }
            if (i === 7) {
              return (
                <li key={label}>
                  ✓ {label}
                </li>
              )
            }
            return (
              <li key={label}>
                ✓ {label}
              </li>
            )
          })}
        </ol>
      </div>
    )
  }

  const stepVisual = (index: number): StepVisual => {
    if (serverFailed) {
      if (index < visualDone) return 'done'
      if (index === visualDone) return 'failed'
      return 'pending'
    }
    if (index < visualDone) return 'done'
    if (index === visualDone && importPending && visualDone < STEP_COUNT) return 'running'
    return 'pending'
  }

  const subFor = (index: number): string | undefined => {
    const ir = normalizeImportResult(liveBatch?.import_result ?? null)
    if (index === 3 && parseSnapshot && stepVisual(3) === 'running') {
      return `CSV rows read so far: ${formatInt(parseSnapshot.csvRowsRead)}`
    }
    if (index === 4 && parseSnapshot && stepVisual(4) === 'running') {
      return `CSV rows staged so far: ${formatInt(parseSnapshot.rowsStaged)}`
    }
    if (index === 5 && applyStarted && !applyFinished) {
      return 'Replacing prior Sales Daily Sheets rows for this salon in the uploaded date range…'
    }
    if (index === 6 && applyStarted && !applyFinished) {
      return 'Building sales_transactions rows from this import…'
    }
    if (index === 3 && ir?.csv_rows_read != null && stepVisual(3) === 'done') {
      return `${formatInt(ir.csv_rows_read)}`
    }
    if (index === 4 && ir?.csv_rows_staged != null && stepVisual(4) === 'done') {
      return `${formatInt(ir.csv_rows_staged)}`
    }
    return undefined
  }

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
        Large files can take a few minutes. Steps below follow the real pipeline; when several
        finish at once, checkmarks appear one after another so the sequence is easier to follow.
      </p>
      <ol className="mt-3 list-none space-y-2.5 pl-0">
        {STEP_LABELS.map((label, index) => {
          const state = stepVisual(index)
          return (
            <li key={label} className="flex gap-2 text-sm">
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
                </p>
                {subFor(index) ? (
                  <p className="mt-0.5 text-xs text-slate-500">{subFor(index)}</p>
                ) : null}
              </div>
            </li>
          )
        })}
      </ol>
      {liveBatch?.error_message && serverFailed ? (
        <p className="mt-3 rounded border border-red-200 bg-red-50/80 px-2 py-1.5 text-xs text-red-900">
          <span className="font-medium">Something went wrong: </span>
          {liveBatch.error_message}
        </p>
      ) : null}
      {errorText && serverFailed && !liveBatch?.error_message ? (
        <p className="mt-3 rounded border border-red-200 bg-red-50/80 px-2 py-1.5 text-xs text-red-900">
          {errorText}
        </p>
      ) : null}
    </div>
  )
}
