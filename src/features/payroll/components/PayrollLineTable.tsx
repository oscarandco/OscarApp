import { useMemo, useState } from 'react'

import {
  ColumnReorderHandle,
  TableColumnSortHeader,
} from '@/components/ui/TableColumnSortHeader'
import { PayrollLineColumnPicker } from '@/features/payroll/components/PayrollLineColumnPicker'
import { usePayrollLineColumnPreferences } from '@/features/payroll/hooks/usePayrollLineColumnPreferences'
import {
  isLineColumnId,
  lineRowKeysForPreferences,
  LINE_COLUMN_LABEL,
  reorderLineColumnOrder,
  visibleLineColumns,
  type LineColumnId,
} from '@/features/payroll/payrollLineTableColumns'
import { TableScrollArea } from '@/components/ui/TableScrollArea'
import type { WeeklyCommissionLineRow } from '@/features/payroll/types'
import { isEmptyish, formatScalarText } from '@/lib/cellValue'
import {
  formatCommissionRatePercent,
  formatNzd,
  formatShortDate,
  tableColumnTitle,
} from '@/lib/formatters'
import { stylistPaidFromLine, workPerformedByFromLine } from '@/lib/payrollLineDisplay'
import type { ColumnSortState } from '@/lib/tableSort'
import { sortPayrollLineRows } from '@/lib/payrollLineTableSort'

type PayrollLineTableProps = {
  rows: WeeklyCommissionLineRow[]
  /**
   * `fillViewport`: table sits in a flex child with `min-h-0 flex-1 overflow-auto` so
   * horizontal and vertical scrollbars stay on the table frame (admin / stylist week detail).
   */
  scrollFrame?: 'default' | 'fillViewport'
  /** `compact`: smaller type/padding, wrapped headers, truncated long text cells. */
  density?: 'default' | 'compact'
}

const thDefault =
  'border-b border-slate-200 px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-4 sm:py-3 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700'
const tdDefault =
  'whitespace-nowrap px-3 py-2.5 text-slate-700 sm:px-4 sm:py-3 min-w-[5rem]'

const thCompact =
  'border-b border-slate-200 px-2 py-1 text-left align-top text-xs font-semibold leading-snug text-slate-600 sm:text-slate-700'
const tdCompact =
  'border-b border-slate-100 px-2 py-1 align-top text-xs leading-tight text-slate-700 min-w-0'

function isDateLikeKey(rowKey: string): boolean {
  if (
    rowKey === 'sale_date' ||
    rowKey === 'pay_date' ||
    rowKey === 'pay_week_end' ||
    rowKey === 'sale_datetime'
  ) {
    return true
  }
  if (rowKey.includes('_date') || rowKey.endsWith('_at')) return true
  return rowKey.includes('week') && rowKey.includes('start')
}

function isNumericColumnKey(k: string): boolean {
  return (
    k.includes('amount') ||
    k.includes('commission') ||
    k.includes('price_ex_gst') ||
    k.includes('price_incl_gst') ||
    k.includes('quantity') ||
    k === 'actual_commission_rate'
  )
}

/** Long free-text columns: ellipsis + title in compact admin layout. */
function shouldTruncateRowKey(k: string): boolean {
  if (k === '__work_performed_by' || k === '__stylist_paid') return true
  switch (k) {
    case 'customer_name':
    case 'product_service_name':
    case 'commission_product_service':
    case 'product_type_actual':
    case 'product_type_short':
    case 'commission_category_final':
    case 'stylist_visible_note':
    case 'invoice':
    case 'derived_staff_paid_display_name':
    case 'derived_staff_paid_full_name':
      return true
    default:
      return false
  }
}

function headerLabel(id: LineColumnId, rowKey: string): string {
  return LINE_COLUMN_LABEL[id] ?? tableColumnTitle(rowKey)
}

function lineCellValue(row: WeeklyCommissionLineRow, rowKey: string): unknown {
  if (rowKey === '__work_performed_by') {
    const t = workPerformedByFromLine(row)
    return t === '' ? null : t
  }
  if (rowKey === '__stylist_paid') {
    const t = stylistPaidFromLine(row)
    return t === '' ? null : t
  }
  return row[rowKey as keyof WeeklyCommissionLineRow]
}

function Cell({
  rowKey,
  value,
  truncate,
}: {
  rowKey: string
  value: unknown
  truncate?: boolean
}) {
  if (isEmptyish(value)) return <span className="text-slate-400">—</span>
  if (typeof value === 'boolean') {
    return <span>{value ? 'Yes' : 'No'}</span>
  }
  if (rowKey === 'quantity') {
    const n = typeof value === 'number' ? value : Number(value)
    return (
      <span className="tabular-nums">
        {Number.isNaN(n) ? '—' : n.toLocaleString()}
      </span>
    )
  }
  if (rowKey === 'actual_commission_rate') {
    return (
      <span className="tabular-nums">{formatCommissionRatePercent(value)}</span>
    )
  }
  if (
    rowKey.includes('amount') ||
    rowKey.includes('commission') ||
    rowKey.includes('price_ex_gst') ||
    rowKey.includes('price_incl_gst') ||
    rowKey.includes('sales') ||
    rowKey.includes('amt_ex_gst')
  ) {
    return <span className="tabular-nums">{formatNzd(value)}</span>
  }
  if (isDateLikeKey(rowKey)) {
    return <span className="whitespace-nowrap">{formatShortDate(String(value))}</span>
  }
  if (typeof value === 'object' && value !== null) {
    return (
      <span className="font-mono text-xs">{JSON.stringify(value)}</span>
    )
  }
  const text = formatScalarText(value)
  if (text === '') return <span className="text-slate-400">—</span>
  if (truncate) {
    return (
      <span className="block min-w-0 truncate whitespace-nowrap" title={text}>
        {text}
      </span>
    )
  }
  return <span>{text}</span>
}

function stableLineRowKey(row: WeeklyCommissionLineRow, index: number): string {
  const id = row.id
  if (id != null && String(id).trim() !== '') {
    return `id:${String(id).trim()}`
  }
  const inv = row.invoice
  if (inv != null && String(inv).trim() !== '') {
    const sd =
      row.sale_date != null && String(row.sale_date).trim() !== ''
        ? String(row.sale_date).trim()
        : 'nodate'
    return `inv:${String(inv).trim()}-${sd}-${index}`
  }
  const pw =
    row.pay_week_start != null && String(row.pay_week_start).trim() !== ''
      ? String(row.pay_week_start).trim()
      : 'nopw'
  return `line:${pw}-${index}`
}

const DND_TYPE = 'application/x-payroll-line-column'

export function PayrollLineTable({
  rows,
  scrollFrame = 'default',
  density = 'default',
}: PayrollLineTableProps) {
  const { prefs, setPrefs, reset } = usePayrollLineColumnPreferences()
  const [draggingId, setDraggingId] = useState<LineColumnId | null>(null)
  const [dropTargetId, setDropTargetId] = useState<LineColumnId | null>(null)
  const [lineSort, setLineSort] = useState<ColumnSortState>(null)

  const sample = rows[0]

  const displayRows = useMemo(
    () => sortPayrollLineRows(rows, lineSort),
    [rows, lineSort],
  )

  const keys = useMemo(
    () => (sample ? lineRowKeysForPreferences(sample, prefs) : []),
    [sample, prefs],
  )

  const visibleCols = useMemo(
    () => (sample ? visibleLineColumns(sample, prefs) : []),
    [sample, prefs],
  )

  const compact = density === 'compact'
  const fillViewport = scrollFrame === 'fillViewport'
  const th = compact ? thCompact : thDefault
  const td = compact ? tdCompact : tdDefault

  if (!rows.length) {
    return null
  }

  function onDragStart(e: React.DragEvent, id: LineColumnId) {
    e.dataTransfer.setData(DND_TYPE, id)
    e.dataTransfer.setData('text/plain', id)
    e.dataTransfer.effectAllowed = 'move'
    setDraggingId(id)
    setDropTargetId(null)
  }

  function onDragOverCol(e: React.DragEvent, id: LineColumnId) {
    e.preventDefault()
    e.dataTransfer.dropEffect = 'move'
    if (draggingId && draggingId !== id) setDropTargetId(id)
  }

  function onDropOnCol(e: React.DragEvent, targetId: LineColumnId) {
    e.preventDefault()
    const raw =
      e.dataTransfer.getData(DND_TYPE) || e.dataTransfer.getData('text/plain')
    const fromId = isLineColumnId(raw) ? raw : null
    setDraggingId(null)
    setDropTargetId(null)
    if (fromId == null || fromId === targetId) return
    setPrefs((prev) => ({
      ...prev,
      order: reorderLineColumnOrder(prev.order, fromId, targetId),
    }))
  }

  function onDragEnd() {
    setDraggingId(null)
    setDropTargetId(null)
  }

  const outerClass = fillViewport
    ? 'flex min-h-0 min-w-0 w-full flex-1 flex-col gap-2'
    : 'space-y-2'
  const scrollFrameClass =
    'min-h-0 min-w-0 w-full flex-1 overflow-auto rounded-lg border border-slate-200 bg-white shadow-sm [-webkit-overflow-scrolling:touch]'

  const tableInner = (
    <table
      className={`w-full border-collapse text-left ${compact ? 'min-w-[760px] text-xs' : 'min-w-[880px] text-sm'}`}
    >
      <thead className="sticky top-0 z-20 bg-slate-50 shadow-[0_1px_0_0_rgb(226_232_240)]">
        <tr>
          {visibleCols.map(({ id, rowKey: k }) => {
            const isDragging = draggingId === id
            const isDropTarget =
              dropTargetId === id && draggingId != null && draggingId !== id
            const isNumeric = isNumericColumnKey(k)
            const headerRowAlign = compact ? 'items-start' : 'items-center'
            const thSizing = compact
              ? `${isNumeric ? 'min-w-0 whitespace-nowrap' : shouldTruncateRowKey(k) ? 'max-w-[11rem] min-w-0' : 'min-w-0'}`
              : 'min-w-[6rem]'
            return (
              <th
                key={`${id}-${k}`}
                scope="col"
                className={`${th} ${thSizing} ${isNumeric ? 'text-right' : ''}`}
              >
                <div className={`flex min-w-0 gap-0.5 ${headerRowAlign}`}>
                  <div className="min-w-0 flex-1">
                    <TableColumnSortHeader
                      label={headerLabel(id, k)}
                      columnKey={k}
                      sortState={lineSort}
                      onSortChange={setLineSort}
                      align={isNumeric ? 'right' : 'left'}
                      wrapLabel={compact && !isNumeric}
                    />
                  </div>
                  <ColumnReorderHandle
                    dragging={isDragging}
                    isDropTarget={isDropTarget}
                    onDragStart={(e) => onDragStart(e, id)}
                    onDragOver={(e) => onDragOverCol(e, id)}
                    onDrop={(e) => onDropOnCol(e, id)}
                    onDragEnd={onDragEnd}
                  />
                </div>
              </th>
            )
          })}
        </tr>
      </thead>
      <tbody>
        {displayRows.map((row, idx) => (
          <tr
            key={stableLineRowKey(row, idx)}
            className="border-b border-slate-100 odd:bg-white even:bg-slate-50/90 hover:bg-violet-50/60"
          >
            {keys.map((k) => {
              const isNumeric = isNumericColumnKey(k)
              const trunc = compact && shouldTruncateRowKey(k)
              const tdSizing = compact
                ? trunc
                  ? 'max-w-[11rem] min-w-0'
                  : isNumeric
                    ? 'whitespace-nowrap'
                    : ''
                : ''
              const tdAlign = compact && isNumeric ? 'text-right' : ''
              return (
                <td key={k} className={`${td} ${tdSizing} ${tdAlign}`.trim()}>
                  <Cell
                    rowKey={k}
                    value={lineCellValue(row, k)}
                    truncate={trunc}
                  />
                </td>
              )
            })}
          </tr>
        ))}
      </tbody>
    </table>
  )

  return (
    <div className={outerClass}>
      <div className="flex shrink-0 justify-end">
        <PayrollLineColumnPicker prefs={prefs} onChange={setPrefs} onReset={reset} />
      </div>
      {fillViewport ? (
        <>
          <p className="pl-0.5 text-xs text-slate-500 sm:hidden" aria-hidden>
            Scroll horizontally for all columns →
          </p>
          <div
            className={scrollFrameClass}
            data-testid="payroll-line-table"
          >
            {tableInner}
          </div>
        </>
      ) : (
        <TableScrollArea testId="payroll-line-table">{tableInner}</TableScrollArea>
      )}
    </div>
  )
}
