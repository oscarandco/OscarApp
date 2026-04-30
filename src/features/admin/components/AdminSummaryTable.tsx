import type { ReactNode } from 'react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { useQuery } from '@tanstack/react-query'

import {
  ColumnReorderHandle,
  TableColumnSortHeader,
} from '@/components/ui/TableColumnSortHeader'
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
import { PayrollLinesPreviewModal } from '@/features/payroll/components/PayrollLinesPreviewModal'
import { WeeklySummaryColumnPicker } from '@/features/payroll/components/WeeklySummaryColumnPicker'
import { usePayrollSummaryColumnPreferences } from '@/features/payroll/hooks/usePayrollSummaryColumnPreferences'
import {
  isMiddleColumnId,
  middleRowKeysForPreferences,
  reorderMiddleColumnOrder,
  salesSummaryAlignedMiddleColumnLabel,
  visibleMiddleColumns,
  type MiddleColumnId,
} from '@/features/payroll/weeklySummaryTableColumns'
import { TableScrollArea } from '@/components/ui/TableScrollArea'
import type { AdminPayrollSummaryRow } from '@/features/admin/types'
import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { isEmptyish, formatScalarText } from '@/lib/cellValue'
import {
  adminSummaryCellValue,
  stylistPaidFromAdminSummaryRow,
} from '@/lib/adminSummaryTableCells'
import {
  formatDateLabel,
  formatNzd,
  formatShortDate,
} from '@/lib/formatters'
import { prioritizeSelfInWorkPerformedByDisplay } from '@/lib/prioritizeSelfInWorkPerformedByDisplay'
import { filterCommissionLinesForSummaryRow } from '@/lib/payrollSummaryFilters'
import type { ColumnSortState } from '@/lib/tableSort'
import {
  ADMIN_SUMMARY_SORT_PAY_WEEK_START,
  sortAdminCommissionSummaryRows,
} from '@/lib/adminCommissionSummarySort'
import {
  sortStylistCommissionSummaryRows,
  STYLIST_SUMMARY_SORT_PAY_WEEK_START,
} from '@/lib/weeklyCommissionSummarySort'
import { rpcGetAdminPayrollLinesWeekly } from '@/lib/supabaseRpc'

const thBase =
  'border-b border-slate-200 px-3 py-2 text-left align-top text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-3.5 sm:py-2 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700 whitespace-normal'
const tdBase =
  'whitespace-nowrap px-3 py-2 text-slate-700 sm:px-3.5 sm:py-2 min-w-[6.5rem]'

function isDateLikeKey(rowKey: string): boolean {
  if (rowKey === 'pay_week_start') return false
  if (rowKey === 'pay_week_end' || rowKey === 'pay_date') return true
  if (rowKey.includes('_date') || rowKey.endsWith('_at')) return true
  return rowKey.includes('week') && rowKey.includes('start')
}

function Cell({
  rowKey,
  value,
  workPerformedBySelfMatchNames,
}: {
  rowKey: string
  value: unknown
  workPerformedBySelfMatchNames?: readonly string[] | null
}) {
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
  if (
    rowKey === 'work_performed_by' ||
    rowKey === '__admin_summary_work_performed'
  ) {
    const text = formatScalarText(value)
    if (text === '') return <span className="text-slate-400">—</span>
    const shown =
      workPerformedBySelfMatchNames != null &&
      workPerformedBySelfMatchNames.length > 0
        ? prioritizeSelfInWorkPerformedByDisplay(
            text,
            workPerformedBySelfMatchNames,
          )
        : text
    return <span>{shown}</span>
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

const DND_TYPE_ADMIN = 'application/x-admin-payroll-middle-column'
const DND_TYPE_MY_SALES = 'application/x-my-sales-payroll-middle-column'

export type MySalesSummaryTableOptions = {
  forceHiddenColumnIds: ReadonlySet<MiddleColumnId>
  showColumnPicker: boolean
  workPerformedBySelfMatchNames?: readonly string[] | null
}

type AdminSummaryTableProps = {
  rows: AdminPayrollSummaryRow[]
  /** When true, line detail links scope to one location; when false, staff across all locations. */
  splitByLocation: boolean
  tableStructureSample?: AdminPayrollSummaryRow | null
  emptyBodyMessage?: string
  toolbarDataSources?: ReactNode
  toolbarDateRange?: ReactNode
  /** My Sales: same table chrome as admin; stylist column prefs, Link + modal, self-first work performed. */
  mySalesTableOptions?: MySalesSummaryTableOptions | null
}

function AdminSummaryTableAdmin({
  rows,
  splitByLocation,
  tableStructureSample = null,
  emptyBodyMessage,
  toolbarDataSources,
  toolbarDateRange,
}: Omit<AdminSummaryTableProps, 'mySalesTableOptions'>) {
  void splitByLocation
  const { prefs, setPrefs, reset } = useAdminPayrollSummaryColumnPreferences()
  const [draggingId, setDraggingId] = useState<AdminMiddleColumnId | null>(null)
  const [dropTargetId, setDropTargetId] = useState<AdminMiddleColumnId | null>(
    null,
  )
  const [previewSummaryRow, setPreviewSummaryRow] =
    useState<AdminPayrollSummaryRow | null>(null)
  const [summarySort, setSummarySort] = useState<ColumnSortState>(null)

  const sample = rows[0] ?? tableStructureSample ?? null

  const displayRows = useMemo(
    () => sortAdminCommissionSummaryRows(rows, summarySort),
    [rows, summarySort],
  )

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
    e.dataTransfer.setData(DND_TYPE_ADMIN, id)
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
      e.dataTransfer.getData(DND_TYPE_ADMIN) ||
      e.dataTransfer.getData('text/plain')
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
    previewSummaryRow != null
      ? stylistPaidFromAdminSummaryRow(previewSummaryRow)
      : '—'

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
                <TableColumnSortHeader
                  label="Pay week start"
                  columnKey={ADMIN_SUMMARY_SORT_PAY_WEEK_START}
                  sortState={summarySort}
                  onSortChange={setSummarySort}
                  wrapLabel
                />
              </th>
              {visibleMiddle.map(({ id, rowKey: k }) => {
                const isDragging = draggingId === id
                const isDropTarget =
                  dropTargetId === id && draggingId != null && draggingId !== id
                return (
                  <th
                    key={`${id}-${k}`}
                    scope="col"
                    className={`${thBase} max-w-[9.5rem] sm:max-w-[11rem]`}
                  >
                    <div className="flex min-w-0 items-start gap-0.5">
                      <div className="min-w-0 flex-1">
                        <TableColumnSortHeader
                          label={adminMiddleColumnLabel(id)}
                          columnKey={k}
                          sortState={summarySort}
                          onSortChange={setSummarySort}
                          wrapLabel
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
            {displayRows.map((row, idx) => {
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

function AdminSummaryTableMySales({
  rows,
  splitByLocation,
  tableStructureSample = null,
  emptyBodyMessage,
  toolbarDataSources,
  toolbarDateRange,
  mySales,
}: Omit<AdminSummaryTableProps, 'mySalesTableOptions'> & {
  mySales: MySalesSummaryTableOptions
}) {
  void splitByLocation
  const { prefs, setPrefs, reset } = usePayrollSummaryColumnPreferences()
  const { forceHiddenColumnIds, showColumnPicker, workPerformedBySelfMatchNames } =
    mySales
  const [draggingId, setDraggingId] = useState<MiddleColumnId | null>(null)
  const [dropTargetId, setDropTargetId] = useState<MiddleColumnId | null>(null)
  const [previewSummaryRow, setPreviewSummaryRow] =
    useState<WeeklyCommissionSummaryRow | null>(null)
  const [summarySort, setSummarySort] = useState<ColumnSortState>(null)

  const sampleRow = rows[0] ?? tableStructureSample ?? null
  const sample = sampleRow as WeeklyCommissionSummaryRow | null

  const displayRows = useMemo(
    () =>
      sortStylistCommissionSummaryRows(
        rows as WeeklyCommissionSummaryRow[],
        summarySort,
      ),
    [rows, summarySort],
  )

  const keys = useMemo(
    () =>
      sample ? middleRowKeysForPreferences(sample, prefs, forceHiddenColumnIds) : [],
    [sample, prefs, forceHiddenColumnIds],
  )

  const visibleMiddle = useMemo(
    () =>
      sample
        ? visibleMiddleColumns(sample, prefs, forceHiddenColumnIds)
        : [],
    [sample, prefs, forceHiddenColumnIds],
  )

  const colSpanEmpty = 1 + visibleMiddle.length + 1

  function onDragStart(e: React.DragEvent, id: MiddleColumnId) {
    e.dataTransfer.setData(DND_TYPE_MY_SALES, id)
    e.dataTransfer.setData('text/plain', id)
    e.dataTransfer.effectAllowed = 'move'
    setDraggingId(id)
    setDropTargetId(null)
  }

  function onDragOverCol(e: React.DragEvent, id: MiddleColumnId) {
    e.preventDefault()
    e.dataTransfer.dropEffect = 'move'
    if (draggingId && draggingId !== id) setDropTargetId(id)
  }

  function onDropOnCol(e: React.DragEvent, targetId: MiddleColumnId) {
    e.preventDefault()
    const raw =
      e.dataTransfer.getData(DND_TYPE_MY_SALES) ||
      e.dataTransfer.getData('text/plain')
    const fromId = isMiddleColumnId(raw) ? raw : null
    setDraggingId(null)
    setDropTargetId(null)
    if (fromId == null || fromId === targetId) return
    setPrefs((prev) => ({
      ...prev,
      order: reorderMiddleColumnOrder(prev.order, fromId, targetId),
    }))
  }

  function onDragEnd() {
    setDraggingId(null)
    setDropTargetId(null)
  }

  const showToolbarRow =
    toolbarDataSources != null ||
    toolbarDateRange != null ||
    showColumnPicker === true

  return (
    <div className="space-y-2">
      {showToolbarRow ? (
        <div className="flex w-full min-w-0 flex-col gap-3 sm:flex-row sm:items-center sm:justify-between sm:gap-4">
          <div className="min-w-0 flex-1 text-left">{toolbarDataSources ?? null}</div>
          <div className="flex shrink-0 flex-wrap items-center justify-start gap-2 sm:justify-end sm:gap-3">
            {toolbarDateRange ?? null}
            {showColumnPicker ? (
              <WeeklySummaryColumnPicker
                prefs={prefs}
                onChange={setPrefs}
                onReset={reset}
              />
            ) : null}
          </div>
        </div>
      ) : null}
      <TableScrollArea testId="weekly-summary-table">
        <table className="min-w-[760px] w-full border-collapse text-left text-sm">
          <thead className="sticky top-0 z-20 bg-slate-50 shadow-[0_1px_0_0_rgb(226_232_240)]">
            <tr>
              <th
                scope="col"
                className={`${thBase} sticky left-0 z-30 min-w-[8.5rem] bg-slate-50`}
              >
                <TableColumnSortHeader
                  label="Pay week start"
                  columnKey={STYLIST_SUMMARY_SORT_PAY_WEEK_START}
                  sortState={summarySort}
                  onSortChange={setSummarySort}
                  wrapLabel
                />
              </th>
              {visibleMiddle.map(({ id, rowKey: k }) => {
                const isDragging = draggingId === id
                const isDropTarget =
                  dropTargetId === id && draggingId != null && draggingId !== id
                return (
                  <th
                    key={`${id}-${k}`}
                    scope="col"
                    className={`${thBase} max-w-[9.5rem] sm:max-w-[11rem]`}
                  >
                    <div className="flex min-w-0 items-start gap-0.5">
                      <div className="min-w-0 flex-1">
                        <TableColumnSortHeader
                          label={salesSummaryAlignedMiddleColumnLabel(id)}
                          columnKey={k}
                          sortState={summarySort}
                          onSortChange={setSummarySort}
                          wrapLabel
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
            {displayRows.map((row, idx) => {
              const weekRaw = row.pay_week_start
              const weekStart =
                weekRaw != null && String(weekRaw).trim() !== ''
                  ? String(weekRaw).trim()
                  : ''
              const rk = stableAdminSummaryRowKey(row as AdminPayrollSummaryRow, idx)
              return (
                <tr
                  key={rk}
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
                      <Cell
                        rowKey={k}
                        value={adminSummaryCellValue(
                          row as AdminPayrollSummaryRow,
                          k,
                        )}
                        workPerformedBySelfMatchNames={
                          workPerformedBySelfMatchNames
                        }
                      />
                    </td>
                  ))}
                  <td className={`${tdBase} min-w-[5.5rem]`}>
                    {weekStart ? (
                      <Link
                        to={`/app/my-sales/${encodeURIComponent(weekStart)}`}
                        onClick={(e) => {
                          if (
                            e.ctrlKey ||
                            e.metaKey ||
                            e.shiftKey ||
                            e.altKey ||
                            e.button !== 0
                          ) {
                            return
                          }
                          e.preventDefault()
                          setPreviewSummaryRow(row)
                        }}
                        className="font-medium text-violet-700 hover:text-violet-900"
                        data-testid="weekly-summary-view-lines"
                      >
                        View lines
                      </Link>
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
      <PayrollLinesPreviewModal
        summaryRow={previewSummaryRow}
        onClose={() => setPreviewSummaryRow(null)}
      />
    </div>
  )
}

export function AdminSummaryTable({
  rows,
  splitByLocation,
  tableStructureSample = null,
  emptyBodyMessage,
  toolbarDataSources,
  toolbarDateRange,
  mySalesTableOptions = null,
}: AdminSummaryTableProps) {
  if (mySalesTableOptions != null) {
    return (
      <AdminSummaryTableMySales
        rows={rows}
        splitByLocation={splitByLocation}
        tableStructureSample={tableStructureSample}
        emptyBodyMessage={emptyBodyMessage}
        toolbarDataSources={toolbarDataSources}
        toolbarDateRange={toolbarDateRange}
        mySales={mySalesTableOptions}
      />
    )
  }
  return (
    <AdminSummaryTableAdmin
      rows={rows}
      splitByLocation={splitByLocation}
      tableStructureSample={tableStructureSample}
      emptyBodyMessage={emptyBodyMessage}
      toolbarDataSources={toolbarDataSources}
      toolbarDateRange={toolbarDateRange}
    />
  )
}
