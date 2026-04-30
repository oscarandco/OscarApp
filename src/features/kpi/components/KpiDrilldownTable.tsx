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

function readVisitInvoicesFromPayload(
  payload: Record<string, unknown> | null | undefined,
): { sale_date: string | null; location_id: string | null; invoice: string }[] {
  if (!payload || !Array.isArray(payload.visit_invoices)) return []
  const out: { sale_date: string | null; location_id: string | null; invoice: string }[] = []
  for (const item of payload.visit_invoices as unknown[]) {
    if (item == null || typeof item !== 'object') continue
    const o = item as Record<string, unknown>
    const invoice = typeof o.invoice === 'string' ? o.invoice.trim() : ''
    if (!invoice) continue
    const sale_date = typeof o.sale_date === 'string' ? o.sale_date : null
    const lid = o.location_id
    const location_id =
      typeof lid === 'string' && lid.trim() !== '' ? lid.trim() : null
    out.push({ sale_date, location_id, invoice })
  }
  return out
}

function visitEntryToInvoiceRef(entry: {
  sale_date: string | null
  location_id: string | null
  invoice: string
}): InvoiceRef {
  return {
    invoice: entry.invoice,
    locationId: entry.location_id,
    saleDate: entry.sale_date,
  }
}

function guestKeyForInvoiceNumbering(r: KpiDrilldownRow): string {
  return (titleCaseGuestName(r.primary_label) ?? r.primary_label ?? '').trim().toLowerCase()
}

/** Per-row "View Invoice" / "View Invoice n" for assistant utilisation (one row per line). */
function buildAssistantInvoiceLinkLabels(rows: KpiDrilldownRow[]): (string | null)[] {
  const labels: (string | null)[] = rows.map(() => null)
  type RowRef = { i: number; r: KpiDrilldownRow; ref: InvoiceRef }
  const withRef: RowRef[] = []
  for (let i = 0; i < rows.length; i++) {
    const ref = resolveInvoiceRef(rows[i])
    if (ref) withRef.push({ i, r: rows[i], ref })
  }
  const byGuest = new Map<string, RowRef[]>()
  for (const x of withRef) {
    const k = guestKeyForInvoiceNumbering(x.r)
    const arr = byGuest.get(k) ?? []
    arr.push(x)
    byGuest.set(k, arr)
  }
  for (const group of byGuest.values()) {
    group.sort((a, b) => {
      const da = String(a.r.event_date ?? '')
      const db = String(b.r.event_date ?? '')
      if (da !== db) return da.localeCompare(db)
      return a.ref.invoice.localeCompare(b.ref.invoice)
    })
    group.forEach((x, ord) => {
      labels[x.i] =
        group.length <= 1 ? 'View Invoice' : `View Invoice ${ord + 1}`
    })
  }
  return labels
}

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
 * (revenue, assistant_utilisation_ratio) also offer a per-row
 * "View Invoice" action that opens an invoice-detail modal.
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
  const [expanded, setExpanded] = useState<Set<number>>(() => new Set())

  const toggle = (idx: number) => {
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(idx)) next.delete(idx)
      else next.add(idx)
      return next
    })
  }

  const visitsValue = (row: KpiDrilldownRow) =>
    kpiCode === 'average_client_spend' ? row.metric_value_2 : row.metric_value
  const spendValue = (row: KpiDrilldownRow) =>
    kpiCode === 'average_client_spend' ? row.metric_value : row.metric_value_2

  const expandedColSpan = 7

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
              Date
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              Visits
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              Spend
            </th>
            <th
              scope="col"
              className="px-3 py-2 font-semibold"
              aria-label="Invoice actions"
            />
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
            const hasPayload = row.raw_payload != null
            const guestName = titleCaseGuestName(row.primary_label) ?? '—'
            const visitInvoices = readVisitInvoicesFromPayload(row.raw_payload)
            return (
              <Fragment key={idx}>
                <tr className="border-b border-slate-100 align-top">
                  <td className="px-3 py-2 text-xs font-medium text-slate-700">
                    {row.row_type || '—'}
                  </td>
                  <td className="px-3 py-2 text-slate-900">{guestName}</td>
                  <td className="px-3 py-2 text-slate-700">
                    {formatShortDate(row.event_date)}
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums text-slate-800">
                    {formatRawNumber(visitsValue(row))}
                  </td>
                  <td className="px-3 py-2 text-right tabular-nums text-slate-800">
                    {formatNzd(spendValue(row))}
                  </td>
                  <td className="px-3 py-2 text-right">
                    <div className="flex flex-wrap justify-end gap-x-2 gap-y-1">
                      {visitInvoices.map((v, j) => (
                        <button
                          key={`${String(v.sale_date)}-${v.invoice}-${j}`}
                          type="button"
                          onClick={() => onOpenInvoice(visitEntryToInvoiceRef(v))}
                          className="text-xs font-medium text-violet-700 hover:text-violet-900 focus:outline-none focus-visible:underline"
                        >
                          {visitInvoices.length === 1
                            ? 'View Invoice'
                            : `View Invoice ${j + 1}`}
                        </button>
                      ))}
                    </div>
                  </td>
                  <td className="px-3 py-2 text-right">
                    {hasPayload ? (
                      <button
                        type="button"
                        onClick={() => toggle(idx)}
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
              </Fragment>
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
 * Revenue-specific drilldown table. Column order follows the KPI page
 * contract for sales-line KPIs:
 *
 *   Date | Stylist | Guest Name | Invoice Number | Product | Sales ex GST | View Invoice
 *
 * Invoice + product come from the sales-line branch of
 * `private.debug_kpi_drilldown` in migration 20260501590000+ via the
 * row's raw_payload. Rows without an invoice still render; the "View
 * invoice" action is omitted for those.
 */
function SalesLineTable({
  rows,
  onOpenInvoice,
}: {
  rows: KpiDrilldownRow[]
  onOpenInvoice: (ref: InvoiceRef) => void
}) {
  return (
    <div className="-mx-5 overflow-x-auto sm:mx-0">
      <table className="w-full min-w-[840px] text-left text-sm">
        <thead className="border-b border-slate-200 text-[11px] uppercase tracking-wide text-slate-500">
          <tr>
            <th scope="col" className="px-3 py-2 font-semibold">
              Date
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Stylist
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Guest Name
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Invoice Number
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Product
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              Sales ex GST
            </th>
            <th
              scope="col"
              className="px-3 py-2 font-semibold"
              aria-label="Invoice actions"
            />
          </tr>
        </thead>
        <tbody>
          {rows.map((row, idx) => (
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
  const invoiceText = readRawString(row.raw_payload, 'invoice') ?? '—'
  const product = readRawString(row.raw_payload, 'product_service_name') ?? '—'
  const invoiceRef = resolveInvoiceRef(row)

  return (
    <tr className="border-b border-slate-100 align-top">
      <td className="px-3 py-2 text-slate-700">
        {formatShortDate(row.event_date)}
      </td>
      <td className="px-3 py-2 text-slate-700">{stylist}</td>
      <td className="px-3 py-2 text-slate-900">{guestName}</td>
      <td className="px-3 py-2 text-slate-700">{invoiceText}</td>
      <td className="px-3 py-2 text-slate-700">{product}</td>
      <td className="px-3 py-2 text-right tabular-nums text-slate-800">
        {formatNzd(row.metric_value)}
      </td>
      <td className="px-3 py-2 text-right">
        {invoiceRef ? (
          <button
            type="button"
            onClick={() => onOpenInvoice(invoiceRef)}
            className="text-xs font-medium text-violet-700 hover:text-violet-900 focus:outline-none focus-visible:underline"
          >
            View Invoice
          </button>
        ) : null}
      </td>
    </tr>
  )
}

/**
 * Assistant-utilisation-specific drilldown table. Splits the former
 * single "Assistant / Owner Context" field into two explicit columns
 * (Owner, Work Performed By) and, since 20260501590000, also exposes
 * Invoice Number + Product + an invoice-detail popup action — all from
 * the raw_payload populated by the assistant branch of
 * `private.debug_kpi_drilldown`.
 *
 * No KPI math changes: numerator (`Counted in Numerator`) still comes
 * straight from `metric_value_2`, sale price from `metric_value`.
 */
function AssistantUtilisationTable({
  rows,
  onOpenInvoice,
}: {
  rows: KpiDrilldownRow[]
  onOpenInvoice: (ref: InvoiceRef) => void
}) {
  const invoiceLinkLabels = useMemo(
    () => buildAssistantInvoiceLinkLabels(rows),
    [rows],
  )
  return (
    <div className="-mx-5 overflow-x-auto sm:mx-0">
      <table className="w-full min-w-[960px] text-left text-sm">
        <thead className="border-b border-slate-200 text-[11px] uppercase tracking-wide text-slate-500">
          <tr>
            <th scope="col" className="px-3 py-2 font-semibold">
              Type
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Guest Name
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Owner
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Work Performed By
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Invoice Number
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Product
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              Sales ex GST
            </th>
            <th scope="col" className="px-3 py-2 text-right font-semibold">
              Counted in Numerator
            </th>
            <th scope="col" className="px-3 py-2 font-semibold">
              Date
            </th>
            <th
              scope="col"
              className="px-3 py-2 font-semibold"
              aria-label="Invoice actions"
            />
          </tr>
        </thead>
        <tbody>
          {rows.map((row, idx) => (
            <AssistantUtilisationRowFragment
              key={idx}
              row={row}
              onOpenInvoice={onOpenInvoice}
              invoiceLinkLabel={invoiceLinkLabels[idx]}
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
  invoiceLinkLabel: string | null
}) {
  const { row, onOpenInvoice, invoiceLinkLabel } = props
  const guestNameText = titleCaseGuestName(row.primary_label) ?? '—'
  const ownerText = row.secondary_label?.trim() || '—'
  const workPerformedBy = resolveWorkPerformedBy(row.raw_payload) ?? '—'
  const invoiceText = readRawString(row.raw_payload, 'invoice') ?? '—'
  const product = readRawString(row.raw_payload, 'product_service_name') ?? '—'
  const invoiceRef = resolveInvoiceRef(row)

  return (
    <tr className="border-b border-slate-100 align-top">
      <td className="px-3 py-2 text-xs font-medium text-slate-700">
        {row.row_type || '—'}
      </td>
      <td className="px-3 py-2 text-slate-900">{guestNameText}</td>
      <td className="px-3 py-2 text-slate-700">{ownerText}</td>
      <td className="px-3 py-2 text-slate-700">{workPerformedBy}</td>
      <td className="px-3 py-2 text-slate-700">{invoiceText}</td>
      <td className="px-3 py-2 text-slate-700">{product}</td>
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
        {invoiceRef ? (
          <button
            type="button"
            onClick={() => onOpenInvoice(invoiceRef)}
            className="text-xs font-medium text-violet-700 hover:text-violet-900 focus:outline-none focus-visible:underline"
          >
            {invoiceLinkLabel ?? 'View Invoice'}
          </button>
        ) : null}
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
