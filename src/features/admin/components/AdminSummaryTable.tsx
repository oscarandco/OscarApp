import type { ReactNode } from 'react'
import { useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'

import { AdminPayrollLinesPreviewModal } from '@/features/admin/components/AdminPayrollLinesPreviewModal'
import { AdminSummaryColumnPicker } from '@/features/admin/components/AdminSummaryColumnPicker'
import { useAdminPayrollSummaryColumnPreferences } from '@/features/admin/hooks/useAdminPayrollSummaryColumnPreferences'
import {
  adminMiddleColumnLabel,
  adminMiddleRowKeysForPreferences,
  isAdminMiddleColumnId,
  reorderAdminMiddleColumnOrder,
  visibleAdminMiddleColumns,
  type AdminMiddleColumnId,
} from '@/features/admin/adminWeeklySummaryTableColumns'
import { TableScrollArea } from '@/components/ui/TableScrollArea'
import type { AdminPayrollSummaryRow } from '@/features/admin/types'
import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { isEmptyish, formatScalarText } from '@/lib/cellValue'
import { adminSummaryCellValue, stylistPaidFromAdminSummaryRow } from '@/lib/adminSummaryTableCells'
import {
  formatDateLabel,
  formatNzd,
  formatShortDate,
} from '@/lib/formatters'

const thBase =
  'border-b border-slate-200 px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-4 sm:py-3 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700'
const tdBase =
  'whitespace-nowrap px-3 py-2.5 text-slate-700 sm:px-4 sm:py-3 min-w-[6.5rem]'

function isDateLikeKey(rowKey: string): boolean {
  if (rowKey === 'pay_week_start') return false
  if (rowKey === 'pay_week_end' || rowKey === 'pay_date') return true
  if (rowKey.includes('_date') || rowKey.endsWith('_at')) return true
  return rowKey.includes('week') && rowKey.includes('start')
}

function Cell({ rowKey, value }: { rowKey: string; value: unknown }) {
  if (isEmptyish(value)) return <span className="text-slate-400">—</span>
  if (typeof value === 'boolean') {
    return <span>{value ? 'Yes' : 'No'}</span>
  }
  if (
    rowKey === 'row_count' ||
    rowKey === 'line_count' ||
    rowKey === 'unconfigured_paid_staff_line_count' ||
    rowKey === 'payable_line_count' ||
    rowKey === 'expected_no_commission_line_count' ||
    rowKey === 'zero_value_line_count' ||
    rowKey === 'review_line_count'
  ) {
    const n = typeof value === 'number' ? value : Number(value)
    return <span className="tabular-nums">{Number.isNaN(n) ? '—' : String(n)}</span>
  }
  if (
    rowKey.includes('amount') ||
    rowKey.includes('commission') ||
    rowKey.includes('sales') ||
    rowKey.includes('total_sales') ||
    rowKey.includes('price_ex_gst')
  ) {
    if (typeof value === 'number' || typeof value === 'string') {
      return <span className="tabular-nums">{formatNzd(value)}</span>
    }
  }
  if (rowKey === 'pay_week_start') {
    return <span>{formatDateLabel(String(value))}</span>
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

function stableAdminSummaryRowKey(row: AdminPayrollSummaryRow, index: number): string {
  const week =
    row.pay_week_start != null && String(row.pay_week_start).trim() !== ''
      ? String(row.pay_week_start).trim()
      : 'noweek'
  const loc =
    row.location_id != null && String(row.location_id).trim() !== ''
      ? String(row.location_id).trim()
      : 'noloc'
  const uid =
    row.user_id != null && String(row.user_id).trim() !== ''
      ? String(row.user_id).trim()
      : 'nouid'
  return `${week}-${loc}-${uid}-${index}`
}

const DND_TYPE = 'application/x-admin-payroll-middle-column'

type AdminSummaryTableProps = {
  rows: AdminPayrollSummaryRow[]
  /** When true, line detail links scope to one location; when false, staff across all locations. */
  splitByLocation: boolean
  tableStructureSample?: AdminPayrollSummaryRow | null
  emptyBodyMessage?: string
  toolbarDataSources?: ReactNode
  toolbarDateRange?: ReactNode
}

export function AdminSummaryTable({
  rows,
  splitByLocation,
  tableStructureSample = null,
  emptyBodyMessage,
  toolbarDataSources,
  toolbarDateRange,
}: AdminSummaryTableProps) {
  void splitByLocation
  const { prefs, setPrefs, reset } = useAdminPayrollSummaryColumnPreferences()
  const [draggingId, setDraggingId] = useState<AdminMiddleColumnId | null>(null)
  const [dropTargetId, setDropTargetId] = useState<AdminMiddleColumnId | null>(
    null,
  )
  const [previewSummaryRow, setPreviewSummaryRow] =
    useState<AdminPayrollSummaryRow | null>(null)

  const sample = rows[0] ?? tableStructureSample ?? null

  const payWeekForPreview =
    previewSummaryRow != null &&
    String(previewSummaryRow.pay_week_start ?? '').trim() !== ''
      ? String(previewSummaryRow.pay_week_start).trim()
      : ''

  const linesQuery = useQuery({
    queryKey: ['admin-payroll-lines-weekly', payWeekForPreview] as const,
    queryFn: () => rpcGetAdminPayrollLinesWeekly(payWeekForPreview),
    enabled: Boolean(previewSummaryRow && payWeekForPreview),
  })

  const previewLines = useMemo(() => {
    if (!previewSummaryRow || !linesQuery.data) return []
    return filterCommissionLinesForSummaryRow(
      previewSummaryRow as WeeklyCommissionSummaryRow,
      linesQuery.data,
    )
  }, [previewSummaryRow, linesQuery.data])

  const keys = useMemo(
    () => (sample ? adminMiddleRowKeysForPreferences(sample, prefs) : []),
    [sample, prefs],
  )

  const visibleMiddle = useMemo(
    () => (sample ? visibleAdminMiddleColumns(sample, prefs) : []),
    [sample, prefs],
  )

  const colSpanEmpty = 1 + visibleMiddle.length + 1

  function onDragStart(e: React.DragEvent, id: AdminMiddleColumnId) {
    e.dataTransfer.setData(DND_TYPE, id)
    e.dataTransfer.setData('text/plain', id)
    e.dataTransfer.effectAllowed = 'move'
    setDraggingId(id)
    setDropTargetId(null)
  }

  function onDragOverCol(e: React.DragEvent, id: AdminMiddleColumnId) {
    e.preventDefault()
    e.dataTransfer.dropEffect = 'move'
    if (draggingId && draggingId !== id) setDropTargetId(id)
  }

  function onDropOnCol(e: React.DragEvent, targetId: AdminMiddleColumnId) {
    e.preventDefault()
    const raw =
      e.dataTransfer.getData(DND_TYPE) || e.dataTransfer.getData('text/plain')
    const fromId = isAdminMiddleColumnId(raw) ? raw : null
    setDraggingId(null)
    setDropTargetId(null)
    if (fromId == null || fromId === targetId) return
    setPrefs((prev) => ({
      ...prev,
      order: reorderAdminMiddleColumnOrder(prev.order, fromId, targetId),
    }))
  }

  function onDragEnd() {
    setDraggingId(null)
    setDropTargetId(null)
  }

  const previewStaffLabel =
    previewSummaryRow != null ? stylistPaidFromAdminSummaryRow(previewSummaryRow) : '—'

  return (
    <div className="space-y-2">
      <div className="flex w-full min-w-0 flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
        <div className="min-w-0 flex-1 text-left">{toolbarDataSources ?? null}</div>
        <div className="flex shrink-0 flex-wrap items-center justify-start gap-2 sm:justify-end sm:gap-3">
          {toolbarDateRange ?? null}
          <AdminSummaryColumnPicker prefs={prefs} onChange={setPrefs} onReset={reset} />
        </div>
      </div>
      <TableScrollArea testId="admin-summary-table">
        <table className="min-w-[760px] w-full border-collapse text-left text-sm">
          <thead className="sticky top-0 z-20 bg-slate-50 shadow-[0_1px_0_0_rgb(226_232_240)]">
            <tr>
              <th
                scope="col"
                className={`${thBase} sticky left-0 z-30 min-w-[8.5rem] bg-slate-50`}
              >
                Pay week start
              </th>
              {visibleMiddle.map(({ id, rowKey: k }) => {
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
                    className={`${thBase} cursor-grab select-none active:cursor-grabbing ${
                      isDragging ? 'opacity-50' : ''
                    } ${
                      isDropTarget
                        ? 'bg-violet-100/90 ring-1 ring-inset ring-violet-300'
                        : ''
                    }`}
                    aria-grabbed={isDragging}
                  >
                    {adminMiddleColumnLabel(id)}
                  </th>
                )
              })}
              <th scope="col" className={`${thBase} min-w-[5.5rem]`}>
                Detail
              </th>
            </tr>
          </thead>
          <tbody>
            {!rows.length && emptyBodyMessage ? (
              <tr>
                <td
                  colSpan={colSpanEmpty}
                  className="border-b border-slate-100 px-4 py-8 text-center text-sm text-slate-600"
                >
                  {emptyBodyMessage}
                </td>
              </tr>
            ) : null}
            {rows.map((row, idx) => {
              const weekRaw = row.pay_week_start
              const weekStart =
                weekRaw != null && String(weekRaw).trim() !== ''
                  ? String(weekRaw).trim()
                  : ''
              const rowKey = stableAdminSummaryRowKey(row, idx)
              return (
                <tr
                  key={rowKey}
                  className="group border-b border-slate-100 odd:bg-white even:bg-slate-50/90 hover:bg-violet-50/60"
                >
                  <td
                    className={`${tdBase} sticky left-0 z-10 min-w-[8.5rem] border-slate-100 font-medium ${
                      idx % 2 === 0 ? 'bg-white' : 'bg-slate-50/90'
                    } group-hover:bg-violet-50/60`}
                  >
                    {weekStart ? (
                      <Cell rowKey="pay_week_start" value={row.pay_week_start} />
                    ) : (
                      <span className="text-slate-400">—</span>
                    )}
                  </td>
                  {keys.map((k) => (
                    <td key={k} className={tdBase}>
                      <Cell rowKey={k} value={adminSummaryCellValue(row, k)} />
                    </td>
                  ))}
                  <td className={`${tdBase} min-w-[5.5rem]`}>
                    {weekStart ? (
                      <button
                        type="button"
                        onClick={() => setPreviewSummaryRow(row)}
                        className="font-medium text-violet-700 hover:text-violet-900"
                        data-testid="admin-summary-view-lines"
                      >
                        View lines
                      </button>
                    ) : (
                      <span className="text-slate-400">—</span>
                    )}
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </TableScrollArea>
      <AdminPayrollLinesPreviewModal
        open={previewSummaryRow != null}
        onClose={() => setPreviewSummaryRow(null)}
        payWeekStart={payWeekForPreview}
        staffLabel={previewStaffLabel}
        lines={previewLines}
        isLoading={linesQuery.isLoading}
      />
    </div>
  )
}
