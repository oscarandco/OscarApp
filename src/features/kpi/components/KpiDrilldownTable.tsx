import { Fragment, useMemo, useState } from 'react'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import type {
  KpiDrilldownRow,
  KpiSnapshotScope,
} from '@/features/kpi/data/kpiApi'
import { useKpiDrilldown } from '@/features/kpi/hooks/useKpiDrilldown'
import {
  drilldownColumnsFor,
  formatRawNumber,
  metaFor,
  titleCaseGuestName,
  type KpiDrilldownColumns,
} from '@/features/kpi/kpiLabels'
import { formatNzd, formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'

import { InvoiceDetailModal } from './InvoiceDetailModal'

/**
 * Client-retention KPIs use a bespoke drilldown column layout:
 *
 *   Type | Normalised Name | Retention Status |
 *   Date of first visit | Date of last visit | View
 *
 * The two visit dates are sourced from `raw_payload.first_visit_in_window`
 * and `raw_payload.last_visit_in_window`, populated by the
 * retention branches of `private.debug_kpi_drilldown`. Every other KPI
 * continues to render the generic 10-column table unchanged.
 */
const RETENTION_KPI_CODES: ReadonlySet<string> = new Set([
  'client_retention_6m',
  'client_retention_12m',
  'new_client_retention_6m',
  'new_client_retention_12m',
])

const ASSISTANT_UTILISATION_KPI = 'assistant_utilisation_ratio'
const REVENUE_KPI = 'revenue'

/** Guest-aggregate KPIs: custom column order + visit invoice list in raw_payload. */
const GUEST_METRICS_DRILLDOWN_KPIS: ReadonlySet<string> = new Set([
  'guests_per_month',
  'new_clients_per_month',
  'average_client_spend',
])

function readRawDate(
  payload: Record<string, unknown> | null | undefined,
  key: string,
): string | null {
  if (!payload) return null
  const v = payload[key]
  return typeof v === 'string' && v.length > 0 ? v : null
}

function readRawString(
  payload: Record<string, unknown> | null | undefined,
  key: string,
): string | null {
  if (!payload) return null
  const v = payload[key]
  if (typeof v !== 'string') return null
  const t = v.trim()
  return t.length > 0 ? t : null
}

/**
 * Resolve the staff member who physically did the work for an
 * assistant_utilisation_ratio drilldown row. Falls back through the
 * display → full → raw name chain populated by the assistant branch of
 * `private.debug_kpi_drilldown` (20260501580000+).
 */
function resolveWorkPerformedBy(
  payload: Record<string, unknown> | null | undefined,
): string | null {
  return (
    readRawString(payload, 'staff_work_display_name') ??
    readRawString(payload, 'staff_work_full_name') ??
    readRawString(payload, 'staff_work_name')
  )
}

/**
 * Identifier tuple used to open the invoice-detail popup. Copied
 * verbatim out of the drilldown row's raw_payload. A row without a
 * non-empty `invoice` cannot open the popup.
 */
type InvoiceRef = {
  invoice: string
  locationId: string | null
  saleDate: string | null
}

function resolveInvoiceRef(row: KpiDrilldownRow): InvoiceRef | null {
  const invoice = readRawString(row.raw_payload, 'invoice')
  if (!invoice) return null
  const locationId =
    row.location_id ??
    (readRawString(row.raw_payload, 'location_id') || null)
  const saleDate = row.event_date ?? readRawDate(row.raw_payload, 'sale_date')
  return { invoice, locationId, saleDate }
}

type VisitInvoiceEntry = {
  sale_date: string | null
  location_id: string | null
  invoice: string
  /** Present when the RPC includes per-visit spend (optional). */
  amount_ex_gst?: number | string | null
}

function readVisitInvoicesFromPayload(
  payload: Record<string, unknown> | null | undefined,
): VisitInvoiceEntry[] {
  if (!payload || !Array.isArray(payload.visit_invoices)) return []
  const out: VisitInvoiceEntry[] = []
  for (const item of payload.visit_invoices as unknown[]) {
    if (item == null || typeof item !== 'object') continue
    const o = item as Record<string, unknown>
    const invoice = typeof o.invoice === 'string' ? o.invoice.trim() : ''
    if (!invoice) continue
    const sale_date = typeof o.sale_date === 'string' ? o.sale_date : null
    const lid = o.location_id
    const location_id =
      typeof lid === 'string' && lid.trim() !== '' ? lid.trim() : null
    const rawAmt =
      o.amount_ex_gst ?? o.price_ex_gst ?? o.line_ex_gst ?? o.sale_ex_gst
    let amount_ex_gst: number | string | null | undefined
    if (typeof rawAmt === 'number' && !Number.isNaN(rawAmt)) {
      amount_ex_gst = rawAmt
    } else if (typeof rawAmt === 'string' && rawAmt.trim() !== '') {
      amount_ex_gst = rawAmt.trim()
    }
    out.push({ sale_date, location_id, invoice, amount_ex_gst })
  }
  return out
}

function visitEntryToInvoiceRef(entry: VisitInvoiceEntry): InvoiceRef {
  return {
    invoice: entry.invoice,
    locationId: entry.location_id,
    saleDate: entry.sale_date,
  }
}

/** Oldest visit first, then invoice ascending — matches semicolon lists in Date / Spend. */
function visitInvoicesChronological(
  payload: Record<string, unknown> | null | undefined,
): VisitInvoiceEntry[] {
  const list = readVisitInvoicesFromPayload(payload)
  return [...list].sort((a, b) => {
    const c = String(a.sale_date ?? '').localeCompare(String(b.sale_date ?? ''))
    if (c !== 0) return c
    return a.invoice.localeCompare(b.invoice, undefined, { numeric: true })
  })
}

const INVOICE_NUMBER_BTN_CLASS =
  'text-xs font-medium text-violet-700 hover:text-violet-900 focus:outline-none focus-visible:underline'

function invoiceRefsForDrilldownRow(row: KpiDrilldownRow): InvoiceRef[] {
  const chronological = visitInvoicesChronological(row.raw_payload)
  if (chronological.length > 0) {
    return chronological.map((v) => visitEntryToInvoiceRef(v))
  }
  const single = resolveInvoiceRef(row)
  return single ? [single] : []
}

function ClickableInvoiceNumberList({
  refs,
  onOpenInvoice,
}: {
  refs: InvoiceRef[]
  onOpenInvoice: (ref: InvoiceRef) => void
}) {
  if (refs.length === 0) {
    return <span className="text-slate-400">—</span>
  }
  return (
    <>
      {refs.map((ref, i) => (
        <Fragment key={`${ref.invoice}-${String(ref.saleDate)}-${i}`}>
          {i > 0 ? <span className="text-slate-500">; </span> : null}
          <button
            type="button"
            className={INVOICE_NUMBER_BTN_CLASS}
            onClick={() => onOpenInvoice(ref)}
          >
            {ref.invoice}
          </button>
        </Fragment>
      ))}
    </>
  )
}

/** Descending invoice / document id for stable drilldown ordering. */
function compareInvoiceNumberDesc(a: string, b: string): number {
  return b.localeCompare(a, undefined, { numeric: true })
}

function compareEventDateDesc(
  a: string | null | undefined,
  b: string | null | undefined,
): number {
  return String(b ?? '').localeCompare(String(a ?? ''))
}

function sortSaleLineRows(rows: KpiDrilldownRow[]): KpiDrilldownRow[] {
  return [...rows].sort((x, y) => {
    const c = compareEventDateDesc(x.event_date, y.event_date)
    if (c !== 0) return c
    const ix = readRawString(x.raw_payload, 'invoice') ?? ''
    const iy = readRawString(y.raw_payload, 'invoice') ?? ''
    return compareInvoiceNumberDesc(ix, iy)
  })
}

function guestAggregateSortKeys(row: KpiDrilldownRow): {
  date: string
  invoice: string
} {
  const visits = readVisitInvoicesFromPayload(row.raw_payload)
  if (visits.length === 0) {
    return {
      date: String(row.event_date ?? ''),
      invoice: readRawString(row.raw_payload, 'invoice') ?? '',
    }
  }
  const maxDate = visits.reduce(
    (best, v) => {
      const d = String(v.sale_date ?? '')
      return d > best ? d : best
    },
    '',
  )
  const maxInv = [...visits]
    .map((v) => v.invoice)
    .sort((a, b) => compareInvoiceNumberDesc(a, b))[0] ?? ''
  return {
    date: maxDate || String(row.event_date ?? ''),
    invoice: maxInv,
  }
}

function sortGuestAggregateRows(rows: KpiDrilldownRow[]): KpiDrilldownRow[] {
  return [...rows].sort((x, y) => {
    const kx = guestAggregateSortKeys(x)
    const ky = guestAggregateSortKeys(y)
    const c = compareEventDateDesc(kx.date, ky.date)
    if (c !== 0) return c
    return compareInvoiceNumberDesc(kx.invoice, ky.invoice)
  })
}

function formatGuestDateCellSemicolon(row: KpiDrilldownRow): string {
  const visits = visitInvoicesChronological(row.raw_payload)
  if (visits.length === 0) {
    return row.event_date ? formatShortDate(row.event_date) : '—'
  }
  const uniq: string[] = []
  const seen = new Set<string>()
  for (const v of visits) {
    const d = String(v.sale_date ?? '')
    if (!d || seen.has(d)) continue
    seen.add(d)
    uniq.push(d)
  }
  if (uniq.length === 0) {
    return row.event_date ? formatShortDate(row.event_date) : '—'
  }
  return uniq.map((d) => formatShortDate(d)).join('; ')
}

function formatGuestSpendCellSemicolon(
  visits: VisitInvoiceEntry[],
  spendAgg: number | string | null,
): string {
  if (visits.length <= 1) return formatNzd(spendAgg)
  const parts: string[] = []
  for (const v of visits) {
    if (v.amount_ex_gst == null) continue
    if (typeof v.amount_ex_gst === 'string' && v.amount_ex_gst.trim() === '') continue
    parts.push(formatNzd(v.amount_ex_gst))
  }
  if (parts.length === visits.length && parts.length > 1) {
    return parts.join('; ')
  }
  return formatNzd(spendAgg)
}

/** Shared tighter cell padding for sales-line / guest-metric / assistant drilldowns. */
const DRILL_TH = 'px-2.5 py-1.5 text-[11px] font-semibold uppercase tracking-wide text-slate-500'
const DRILL_TD = 'px-2.5 py-1.5'

type Props = {
  kpiCode: string
  periodStart: string
  scope: KpiSnapshotScope
  locationId: string | null
  staffMemberId: string | null
  enabled: boolean
}

/**
 * Raw-data diagnostic table for the currently-selected KPI. Renders
 * the generic 10-column shape returned by
 * `public.get_kpi_drilldown_live`, with a per-row toggle exposing the
 * `raw_payload` JSON for inspection.
 *
 * Mobile-safe: the table wrapper scrolls horizontally on narrow
 * screens so the columns do not crush each other. Sales-line KPIs
 * (revenue, assistant_utilisation_ratio) open the invoice-detail modal
 * from clickable invoice number(s) in the last column.
 */
export function KpiDrilldownTable(props: Props) {
  const {
    kpiCode,
    periodStart,
    scope,
    locationId,
    staffMemberId,
    enabled,
  } = props
  const meta = metaFor(kpiCode)
  const columns = drilldownColumnsFor(kpiCode)
  const isRetention = RETENTION_KPI_CODES.has(kpiCode)
  const isAssistantUtilisation = kpiCode === ASSISTANT_UTILISATION_KPI
  const isRevenue = kpiCode === REVENUE_KPI

  const { data, isLoading, isError, error, refetch } = useKpiDrilldown({
    kpiCode,
    periodStart,
    scope,
    locationId,
    staffMemberId,
    enabled,
  })

  // One modal instance per drilldown table; state is lifted so
  // SalesLineTable and AssistantUtilisationTable both invoke the same
  // popup via `onOpenInvoice`.
  const [invoiceRef, setInvoiceRef] = useState<InvoiceRef | null>(null)

  return (
    <section
      className="mt-5 rounded-lg border border-slate-200 bg-white p-5 shadow-sm"
      data-testid="kpi-drilldown-panel"
    >
      <header className="mb-3 flex flex-col gap-1 sm:flex-row sm:items-baseline sm:justify-between">
        <div>
          <p className="text-[11px] font-semibold uppercase tracking-wide text-slate-500">
            Underlying rows
          </p>
          <h3 className="mt-0.5 text-base font-semibold text-slate-900">
            {meta.label}
          </h3>
        </div>
        {data ? (
          <p className="text-xs text-slate-500">
            {data.length.toLocaleString()} row{data.length === 1 ? '' : 's'}
          </p>
        ) : null}
      </header>

      <TableBody
        kpiCode={kpiCode}
        isLoading={isLoading}
        isError={isError}
        error={error}
        refetch={refetch}
        data={data}
        columns={columns}
        isRetention={isRetention}
        isAssistantUtilisation={isAssistantUtilisation}
        isRevenue={isRevenue}
        onOpenInvoice={setInvoiceRef}
      />

      <InvoiceDetailModal
        open={invoiceRef !== null}
        onClose={() => setInvoiceRef(null)}
        invoice={invoiceRef?.invoice ?? null}
        locationId={invoiceRef?.locationId ?? null}
        saleDate={invoiceRef?.saleDate ?? null}
      />
    </section>
  )
}

function TableBody(props: {
  kpiCode: string
  isLoading: boolean
  isError: boolean
  error: unknown
  refetch: () => void
  data: KpiDrilldownRow[] | undefined
  columns: KpiDrilldownColumns
  isRetention: boolean
  isAssistantUtilisation: boolean
  isRevenue: boolean
  onOpenInvoice: (ref: InvoiceRef) => void
}) {
  const {
    kpiCode,
    isLoading,
    isError,
    error,
    refetch,
    data,
    columns,
    isRetention,
    isAssistantUtilisation,
    isRevenue,
    onOpenInvoice,
  } = props

  if (isLoading) {
    return <LoadingState testId="kpi-drilldown-loading" />
  }
  if (isError) {
    const detail = queryErrorDetail(error)
    return (
      <ErrorState
        title="Could not load drilldown"
        message={detail.message}
        error={detail.err}
        onRetry={() => refetch()}
        testId="kpi-drilldown-error"
      />
    )
  }
  const rows = data ?? []
  if (rows.length === 0) {
    return (
      <EmptyState
        title="No underlying rows"
        description="No rows were returned for the current KPI and filter combination."
        testId="kpi-drilldown-empty"
      />
    )
  }
  if (isRevenue) {
    return <SalesLineTable rows={rows} onOpenInvoice={onOpenInvoice} />
  }
  if (isAssistantUtilisation) {
    return (
      <AssistantUtilisationTable rows={rows} onOpenInvoice={onOpenInvoice} />
    )
  }
  if (GUEST_METRICS_DRILLDOWN_KPIS.has(kpiCode)) {
    return (
      <GuestMetricsDrilldownTable
        kpiCode={kpiCode}
        rows={rows}
        onOpenInvoice={onOpenInvoice}
      />
    )
  }
  return isRetention ? (
    <RetentionTable rows={rows} />
  ) : (
    <Table rows={rows} columns={columns} />
  )
}

function GuestMetricsDrilldownTable({
  kpiCode,
  rows,
  onOpenInvoice,
}: {
  kpiCode: string
  rows: KpiDrilldownRow[]
  onOpenInvoice: (ref: InvoiceRef) => void
}) {
  const displayRows = useMemo(() => sortGuestAggregateRows(rows), [rows])

  const visitsValue = (row: KpiDrilldownRow) =>
    kpiCode === 'average_client_spend' ? row.metric_value_2 : row.metric_value
  const spendValue = (row: KpiDrilldownRow) =>
    kpiCode === 'average_client_spend' ? row.metric_value : row.metric_value_2

  return (
    <div className="-mx-5 overflow-x-auto sm:mx-0">
      <table className="w-full min-w-[560px] text-left text-sm">
        <thead className="border-b border-slate-200">
          <tr>
            <th scope="col" className={DRILL_TH}>
              Date
            </th>
            <th scope="col" className={DRILL_TH}>
              Guest Name
            </th>
            <th scope="col" className={`${DRILL_TH} text-right`}>
              # Visits
            </th>
            <th scope="col" className={`${DRILL_TH} text-right`}>
              Spend (ex GST)
            </th>
            <th scope="col" className={`${DRILL_TH} text-right`}>
              Invoice
            </th>
          </tr>
        </thead>
        <tbody>
          {displayRows.map((row, idx) => {
            const guestName = titleCaseGuestName(row.primary_label) ?? '—'
            return (
              <tr key={idx} className="border-b border-slate-100 align-top">
                <td className={`${DRILL_TD} text-slate-700`}>
                  {formatGuestDateCellSemicolon(row)}
                </td>
                <td className={`${DRILL_TD} text-slate-900`}>{guestName}</td>
                <td className={`${DRILL_TD} text-right tabular-nums text-slate-800`}>
                  {formatRawNumber(visitsValue(row))}
                </td>
                <td className={`${DRILL_TD} text-right tabular-nums text-slate-800`}>
                  {formatGuestSpendCellSemicolon(
                    visitInvoicesChronological(row.raw_payload),
                    spendValue(row),
                  )}
                </td>
                <td className={`${DRILL_TD} text-right`}>
                  <ClickableInvoiceNumberList
                    refs={invoiceRefsForDrilldownRow(row)}
                    onOpenInvoice={onOpenInvoice}
                  />
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function Table({
  rows,
  columns,
}: {
  rows: KpiDrilldownRow[]
  columns: KpiDrilldownColumns
}) {
  const [expanded, setExpanded] = useState<Set<number>>(() => new Set())

  const toggle = (idx: number) => {
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(idx)) next.delete(idx)
      else next.add(idx)
      return next
    })
  }

  // Collapse duplicate guest-name columns (Guests / New clients /
  // Average client spend / Client frequency). The backend still sends
  // both primary_label (normalised) and secondary_label (raw sample)
  // for those KPIs — we just drop the secondary cell on display.
  const hideSecondary = columns.hideSecondary

  return (
    <div className="-mx-5 overflow-x-auto sm:mx-0">
      <table className="w-full min-w-[720px] text-left text-sm">
        <thead className="border-b border-slate-200 text-[11px] uppercase tracking-wide text-slate-500">
          <tr>
            <th scope="col" className="px-3 py-2 font-semibold">
              Type
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              {columns.primary}
            </th>
            {!hideSecondary ? (
              <th scope="col" className="px-3 py-2 font-semibold">
                {columns.secondary}
              </th>
            ) : null}
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              {columns.metric1}
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              {columns.metric2}
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Date
            </th>
            <th scope="col" className="px-3 py-2 font-semibold" aria-label="Raw details" />
          </tr>
        </thead>
        <tbody>
          {rows.map((row, idx) => {
            const isOpen = expanded.has(idx)
            return (
              <RowFragment
                key={idx}
                row={row}
                idx={idx}
                isOpen={isOpen}
                onToggle={toggle}
                columns={columns}
              />
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

/**
 * Retention-specific drilldown table. Reads first/last visit dates out
 * of the row's `raw_payload` JSONB (populated by the retention branches
 * of `private.debug_kpi_drilldown`). All other generic shape fields are
 * still available via the View toggle.
 */
function RetentionTable({ rows }: { rows: KpiDrilldownRow[] }) {
  const [expanded, setExpanded] = useState<Set<number>>(() => new Set())

  const toggle = (idx: number) => {
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(idx)) next.delete(idx)
      else next.add(idx)
      return next
    })
  }

  return (
    <div className="-mx-5 overflow-x-auto sm:mx-0">
      <table className="w-full min-w-[720px] text-left text-sm">
        <thead className="border-b border-slate-200 text-[11px] uppercase tracking-wide text-slate-500">
          <tr>
            <th scope="col" className="px-3 py-2 font-semibold">
              Type
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Guest Name
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Retention Status
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Date of first visit
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Date of last visit
            </th>
            <th
              scope="col"
              className="px-3 py-2 font-semibold"
              aria-label="Raw details"
            />
          </tr>
        </thead>
        <tbody>
          {rows.map((row, idx) => {
            const isOpen = expanded.has(idx)
            return (
              <RetentionRowFragment
                key={idx}
                row={row}
                idx={idx}
                isOpen={isOpen}
                onToggle={toggle}
              />
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function RowFragment(props: {
  row: KpiDrilldownRow
  idx: number
  isOpen: boolean
  onToggle: (idx: number) => void
  columns: KpiDrilldownColumns
}) {
  const { row, idx, isOpen, onToggle, columns } = props
  const hasPayload = row.raw_payload != null
  const hideSecondary = columns.hideSecondary

  // Title-case the guest column so names always display clean
  // regardless of whether the backend sent the normalised key
  // (already lower-case) or a raw Kitomba name (sometimes upper / mixed
  // case). KPIs whose primary_label is a staff name (e.g.
  // stylist_profitability) have no `guestNameColumn` set and keep
  // their raw casing.
  const primaryText =
    columns.guestNameColumn === 'primary'
      ? titleCaseGuestName(row.primary_label) ?? '—'
      : row.primary_label?.trim() || '—'

  // colSpan for the expanded JSON row has to match the number of
  // visible columns above so the inspector stays full-width when the
  // duplicate guest-name column is collapsed.
  const expandedColSpan = hideSecondary ? 6 : 7

  return (
    <>
      <tr className="border-b border-slate-100 align-top">
        <td className="px-3 py-2 text-xs font-medium text-slate-700">
          {row.row_type || '—'}
        </td>
        <td className="px-3 py-2 text-slate-900">{primaryText}</td>
        {!hideSecondary ? (
          <td className="px-3 py-2 text-slate-700">
            {row.secondary_label?.trim() || '—'}
          </td>
        ) : null}
        <td className="px-3 py-2 text-right tabular-nums text-slate-800">
          {formatRawNumber(row.metric_value)}
        </td>
        <td className="px-3 py-2 text-right tabular-nums text-slate-800">
          {formatRawNumber(row.metric_value_2)}
        </td>
        <td className="px-3 py-2 text-slate-700">
          {formatShortDate(row.event_date)}
        </td>
        <td className="px-3 py-2 text-right">
          {hasPayload ? (
            <button
              type="button"
              onClick={() => onToggle(idx)}
              aria-expanded={isOpen}
              className="text-xs font-medium text-violet-700 hover:text-violet-900 focus:outline-none focus-visible:underline"
            >
              {isOpen ? 'Hide' : 'View'}
            </button>
          ) : null}
        </td>
      </tr>
      {isOpen && hasPayload ? (
        <tr className="border-b border-slate-100 bg-slate-50">
          <td colSpan={expandedColSpan} className="px-3 py-2">
            <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words text-[11px] leading-snug text-slate-700">
              {JSON.stringify(row.raw_payload, null, 2)}
            </pre>
          </td>
        </tr>
      ) : null}
    </>
  )
}

/**
 * Revenue-specific drilldown table. Column order:
 *
 *   Date | Stylist | Guest Name | Product | Spend (ex GST) | Invoice
 *
 * The far-right Invoice column shows clickable invoice number(s); the
 * same modal opens as before.
 */
function SalesLineTable({
  rows,
  onOpenInvoice,
}: {
  rows: KpiDrilldownRow[]
  onOpenInvoice: (ref: InvoiceRef) => void
}) {
  const displayRows = useMemo(() => sortSaleLineRows(rows), [rows])

  return (
    <div className="-mx-5 overflow-x-auto sm:mx-0">
      <table className="w-full min-w-[720px] text-left text-sm">
        <thead className="border-b border-slate-200">
          <tr>
            <th scope="col" className={DRILL_TH}>
              Date
            </th>
            <th scope="col" className={DRILL_TH}>
              Stylist
            </th>
            <th scope="col" className={DRILL_TH}>
              Guest Name
            </th>
            <th scope="col" className={`${DRILL_TH} max-w-[14rem]`}>
              Product
            </th>
            <th scope="col" className={`${DRILL_TH} text-right`}>
              Spend (ex GST)
            </th>
            <th scope="col" className={`${DRILL_TH} text-right`}>
              Invoice
            </th>
          </tr>
        </thead>
        <tbody>
          {displayRows.map((row, idx) => (
            <SalesLineRow
              key={idx}
              row={row}
              onOpenInvoice={onOpenInvoice}
            />
          ))}
        </tbody>
      </table>
    </div>
  )
}

function SalesLineRow(props: {
  row: KpiDrilldownRow
  onOpenInvoice: (ref: InvoiceRef) => void
}) {
  const { row, onOpenInvoice } = props
  const stylist = row.secondary_label?.trim() || '—'
  const guestName = titleCaseGuestName(row.primary_label) ?? '—'
  const product = readRawString(row.raw_payload, 'product_service_name') ?? '—'
  const invoiceRefs = invoiceRefsForDrilldownRow(row)

  return (
    <tr className="border-b border-slate-100 align-top">
      <td className={`${DRILL_TD} text-slate-700`}>
        {formatShortDate(row.event_date)}
      </td>
      <td className={`${DRILL_TD} text-slate-700`}>{stylist}</td>
      <td className={`${DRILL_TD} text-slate-900`}>{guestName}</td>
      <td className={`${DRILL_TD} max-w-[14rem] text-slate-700`}>
        <span
          className="block min-w-0 truncate"
          title={product === '—' ? undefined : product}
        >
          {product}
        </span>
      </td>
      <td className={`${DRILL_TD} text-right tabular-nums text-slate-800`}>
        {formatNzd(row.metric_value)}
      </td>
      <td className={`${DRILL_TD} text-right`}>
        <ClickableInvoiceNumberList
          refs={invoiceRefs}
          onOpenInvoice={onOpenInvoice}
        />
      </td>
    </tr>
  )
}

/**
 * Assistant-utilisation drilldown: one row per qualifying line.
 * Owner + work performer + invoice detail come from `raw_payload`
 * (`private.debug_kpi_drilldown` assistant branch). Rows with
 * `row_type === 'assistant_helped'` — entire row is green and bold;
 * invoice number(s) in the last column stay violet and clickable.
 */
function AssistantUtilisationTable({
  rows,
  onOpenInvoice,
}: {
  rows: KpiDrilldownRow[]
  onOpenInvoice: (ref: InvoiceRef) => void
}) {
  const displayRows = useMemo(() => sortSaleLineRows(rows), [rows])

  return (
    <div className="-mx-5 overflow-x-auto sm:mx-0">
      <table className="w-full min-w-[720px] text-left text-sm">
        <thead className="border-b border-slate-200">
          <tr>
            <th scope="col" className={DRILL_TH}>
              Date
            </th>
            <th scope="col" className={DRILL_TH}>
              Guest Name
            </th>
            <th scope="col" className={DRILL_TH}>
              Owner
            </th>
            <th scope="col" className={DRILL_TH}>
              Work Performed By
            </th>
            <th scope="col" className={`${DRILL_TH} max-w-[14rem]`}>
              Product
            </th>
            <th scope="col" className={`${DRILL_TH} text-right`}>
              Spend (ex GST)
            </th>
            <th scope="col" className={`${DRILL_TH} text-right`}>
              Invoice
            </th>
          </tr>
        </thead>
        <tbody>
          {displayRows.map((row, idx) => (
            <AssistantUtilisationRowFragment
              key={idx}
              row={row}
              onOpenInvoice={onOpenInvoice}
            />
          ))}
        </tbody>
      </table>
    </div>
  )
}

function AssistantUtilisationRowFragment(props: {
  row: KpiDrilldownRow
  onOpenInvoice: (ref: InvoiceRef) => void
}) {
  const { row, onOpenInvoice } = props
  const guestNameText = titleCaseGuestName(row.primary_label) ?? '—'
  const ownerText = row.secondary_label?.trim() || '—'
  const workPerformedBy = resolveWorkPerformedBy(row.raw_payload) ?? '—'
  const product = readRawString(row.raw_payload, 'product_service_name') ?? '—'
  const invoiceRefs = invoiceRefsForDrilldownRow(row)
  const assisted = row.row_type === 'assistant_helped'
  const cellClass = (fallback: string) =>
    `${DRILL_TD} ${assisted ? 'font-semibold text-green-700' : fallback}`

  return (
    <tr className="border-b border-slate-100 align-top">
      <td className={cellClass('text-slate-700')}>
        {formatShortDate(row.event_date)}
      </td>
      <td className={cellClass('text-slate-900')}>{guestNameText}</td>
      <td className={cellClass('text-slate-700')}>{ownerText}</td>
      <td className={cellClass('text-slate-700')}>{workPerformedBy}</td>
      <td className={`${DRILL_TD} max-w-[14rem] ${assisted ? 'font-semibold text-green-700' : 'text-slate-700'}`}>
        <span
          className="block min-w-0 truncate"
          title={product === '—' ? undefined : product}
        >
          {product}
        </span>
      </td>
      <td
        className={`${DRILL_TD} text-right tabular-nums ${assisted ? 'font-semibold text-green-700' : 'text-slate-800'}`}
      >
        {formatNzd(row.metric_value)}
      </td>
      <td
        className={`${DRILL_TD} text-right ${assisted ? 'font-semibold text-green-700' : ''}`}
      >
        <ClickableInvoiceNumberList
          refs={invoiceRefs}
          onOpenInvoice={onOpenInvoice}
        />
      </td>
    </tr>
  )
}

function RetentionRowFragment(props: {
  row: KpiDrilldownRow
  idx: number
  isOpen: boolean
  onToggle: (idx: number) => void
}) {
  const { row, idx, isOpen, onToggle } = props
  const hasPayload = row.raw_payload != null
  const firstVisit = readRawDate(row.raw_payload, 'first_visit_in_window')
  const lastVisit = readRawDate(row.raw_payload, 'last_visit_in_window')
  // Retention drilldowns always put the normalised guest name in
  // `primary_label`, so title-case it unconditionally for a clean
  // `Janet Russel`-style display.
  const guestNameText = titleCaseGuestName(row.primary_label) ?? '—'

  return (
    <>
      <tr className="border-b border-slate-100 align-top">
        <td className="px-3 py-2 text-xs font-medium text-slate-700">
          {row.row_type || '—'}
        </td>
        <td className="px-3 py-2 text-slate-900">{guestNameText}</td>
        <td className="px-3 py-2 text-slate-700">
          {row.secondary_label?.trim() || '—'}
        </td>
        <td className="px-3 py-2 text-slate-700">
          {firstVisit ? formatShortDate(firstVisit) : '—'}
        </td>
        <td className="px-3 py-2 text-slate-700">
          {lastVisit ? formatShortDate(lastVisit) : '—'}
        </td>
        <td className="px-3 py-2 text-right">
          {hasPayload ? (
            <button
              type="button"
              onClick={() => onToggle(idx)}
              aria-expanded={isOpen}
              className="text-xs font-medium text-violet-700 hover:text-violet-900 focus:outline-none focus-visible:underline"
            >
              {isOpen ? 'Hide' : 'View'}
            </button>
          ) : null}
        </td>
      </tr>
      {isOpen && hasPayload ? (
        <tr className="border-b border-slate-100 bg-slate-50">
          <td colSpan={6} className="px-3 py-2">
            <pre className="max-h-64 overflow-auto whitespace-pre-wrap break-words text-[11px] leading-snug text-slate-700">
              {JSON.stringify(row.raw_payload, null, 2)}
            </pre>
          </td>
        </tr>
      ) : null}
    </>
  )
}
