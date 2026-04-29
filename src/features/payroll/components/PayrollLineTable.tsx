import { useMemo, useState } from 'react'

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

type PayrollLineTableProps = {
  rows: WeeklyCommissionLineRow[]
}

const thBase =
  'border-b border-slate-200 px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-4 sm:py-3 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700'
const tdBase =
  'whitespace-nowrap px-3 py-2.5 text-slate-700 sm:px-4 sm:py-3 min-w-[5rem]'

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

function Cell({ rowKey, value }: { rowKey: string; value: unknown }) {
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
    rowKey.includes('sales') ||
    rowKey.includes('amt_ex_gst')
  ) {
    return <span className="tabular-nums">{formatNzd(value)}</span>
  }
  if (isDateLikeKey(rowKey)) {
    return <span>{formatShortDate(String(value))}</span>
  }
  if (typeof value === 'object' && value !== null) {
    return (
      <span className="font-mono text-xs">{JSON.stringify(value)}</span>
    )
  }
  const text = formatScalarText(value)
  return <span>{text === '' ? '—' : text}</span>
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

export function PayrollLineTable({ rows }: PayrollLineTableProps) {
  const { prefs, setPrefs, reset } = usePayrollLineColumnPreferences()
  const [draggingId, setDraggingId] = useState<LineColumnId | null>(null)
  const [dropTargetId, setDropTargetId] = useState<LineColumnId | null>(null)

  const sample = rows[0]

  const keys = useMemo(
    () => (sample ? lineRowKeysForPreferences(sample, prefs) : []),
    [sample, prefs],
  )

  const visibleCols = useMemo(
    () => (sample ? visibleLineColumns(sample, prefs) : []),
    [sample, prefs],
  )

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

  return (
    <div className="space-y-2">
      <div className="flex justify-end">
        <PayrollLineColumnPicker prefs={prefs} onChange={setPrefs} onReset={reset} />
      </div>
      <TableScrollArea testId="payroll-line-table">
        <table className="min-w-[880px] w-full border-collapse text-left text-sm">
          <thead className="sticky top-0 z-20 bg-slate-50 shadow-[0_1px_0_0_rgb(226_232_240)]">
            <tr>
              {visibleCols.map(({ id, rowKey: k }) => {
                const isDragging = draggingId === id
                const isDropTarget =
                  dropTargetId === id && draggingId != null && draggingId !== id
                return (
                  <th
                    key={`${id}-${k}`}
                    scope="col"
                    draggable
                    onDragStart={(e) => onDragStart(e, id)}
                    onDragOver={(e) => onDragOverCol(e, id)}
                    onDrop={(e) => onDropOnCol(e, id)}
                    onDragEnd={onDragEnd}
                    title="Drag to reorder column"
                    className={`${thBase} min-w-[6rem] cursor-grab select-none active:cursor-grabbing ${
                      isDragging ? 'opacity-50' : ''
                    } ${
                      isDropTarget
                        ? 'bg-violet-100/90 ring-1 ring-inset ring-violet-300'
                        : ''
                    }`}
                    aria-grabbed={isDragging}
                  >
                    {headerLabel(id, k)}
                  </th>
                )
              })}
            </tr>
          </thead>
          <tbody>
            {rows.map((row, idx) => (
              <tr
                key={stableLineRowKey(row, idx)}
                className="border-b border-slate-100 odd:bg-white even:bg-slate-50/90 hover:bg-violet-50/60"
              >
                {keys.map((k) => (
                  <td key={k} className={tdBase}>
                    <Cell rowKey={k} value={lineCellValue(row, k)} />
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </TableScrollArea>
    </div>
  )
}
