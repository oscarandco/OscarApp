import type { ReactNode } from 'react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'

import {
  ColumnReorderHandle,
  TableColumnSortHeader,
} from '@/components/ui/TableColumnSortHeader'
import { PayrollLinesPreviewModal } from '@/features/payroll/components/PayrollLinesPreviewModal'
import { WeeklySummaryColumnPicker } from '@/features/payroll/components/WeeklySummaryColumnPicker'
import { usePayrollSummaryColumnPreferences } from '@/features/payroll/hooks/usePayrollSummaryColumnPreferences'
import {
  COLUMN_LABEL,
  isMiddleColumnId,
  reorderMiddleColumnOrder,
  visibleMiddleColumns,
  type MiddleColumnId,
} from '@/features/payroll/weeklySummaryTableColumns'
import { TableScrollArea } from '@/components/ui/TableScrollArea'
import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'
import { isEmptyish, formatScalarText } from '@/lib/cellValue'
import { formatNzd, formatShortDate } from '@/lib/formatters'
import type { ColumnSortState } from '@/lib/tableSort'
import { prioritizeSelfInWorkPerformedByDisplay } from '@/lib/prioritizeSelfInWorkPerformedByDisplay'
import {
  sortStylistCommissionSummaryRows,
  STYLIST_SUMMARY_SORT_PAY_WEEK_START,
} from '@/lib/weeklyCommissionSummarySort'

type WeeklySummaryTableProps = {
  rows: WeeklyCommissionSummaryRow[]
  /**
   * When `rows` is empty (e.g. filters exclude everything) but the table
   * should still render headers + toolbar, supply a representative row
   * for column resolution (typically `sourceRows[0]` from the page).
   */
  tableStructureSample?: WeeklyCommissionSummaryRow | null
  /**
   * Shown in the table body when `rows` is empty. Toolbar + column
   * picker still render when applicable.
   */
  emptyBodyMessage?: string
  /**
   * Sales reporting: data source lines, far left of the toolbar row.
   */
  toolbarDataSources?: ReactNode
  /**
   * Sales reporting: from/to date inputs, immediately left of Columns.
   */
  toolbarDateRange?: ReactNode
  /**
   * Middle column ids that must always be hidden, layered on top of
   * the user's saved column-picker preferences. Owned by the page so
   * role-based hides (Stylist Paid, Potential Commission, Commission
   * payable) and filter-driven hides (Location when Summary rows =
   * Combined) stay in `PayrollSummaryPage` instead of leaking into the
   * shared column-preferences storage.
   */
  forceHiddenColumnIds?: ReadonlySet<MiddleColumnId>
  /**
   * Render the `Columns` button (column-picker trigger). Defaults to
   * `true` so existing callers (admin pages) keep their picker. My
   * Sales passes `false` for stylist and assistant per the role-based
   * visibility helper, since those roles get a fixed column set.
   */
  showColumnPicker?: boolean
  /**
   * Per-column header label overrides. Any id present here uses the
   * mapped string in the table header; columns not listed fall back to
   * the global `COLUMN_LABEL`. Used by My Sales to give stylist /
   * assistant their shorter names (e.g. `Commission`,
   * `Sales (ex GST)`, `Potential Commission`) without changing the
   * default labels admin pages still expect.
   */
  columnLabelOverrides?: Partial<Record<MiddleColumnId, string>>
  /**
   * Mobile-only column hides. Columns named here render with
   * `hidden lg:table-cell` so they disappear below the `lg`
   * breakpoint and stay visible on desktop. The column otherwise
   * stays in the visible-middle pipeline (preferences, ordering,
   * cell formatting), so this is a pure presentation tweak.
   */
  mobileHiddenColumnIds?: ReadonlySet<MiddleColumnId>
  /**
   * Mobile-only header label overrides. Layered over
   * `columnLabelOverrides`: at `<lg` widths the mobile string is
   * rendered, at `>=lg` the desktop string is rendered. Used for
   * shortened headers like `Sales` and `Poss. Comm.` that only fit
   * at phone width.
   */
  mobileColumnLabelOverrides?: Partial<Record<MiddleColumnId, string>>
  /**
   * Mobile-only label for the rightmost fixed `Detail` column. When
   * provided, mobile renders this string and desktop continues to
   * render `Detail`. Stylist/assistant pass `"View"`.
   */
  mobileDetailLabel?: string | null
  /**
   * My Sales only: display names from the access profile used to reorder
   * `work_performed_by` so the logged-in stylist appears first (comma list).
   */
  workPerformedBySelfMatchNames?: readonly string[] | null
}

// Shared padding for even column rhythm (My Sales + admin summary table).
const thBase =
  'border-b border-slate-200 px-2 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:py-2 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700 min-w-0'
const tdBase =
  'px-2 py-2.5 align-top text-slate-700 sm:py-2 min-w-0'

const CURRENCY_MIDDLE_IDS: ReadonlySet<MiddleColumnId> = new Set([
  'total_sales_ex_gst',
  'total_actual_commission_ex_gst',
  'total_theoretical_commission_ex_gst',
  'total_assistant_commission_ex_gst',
])

const NUMERIC_COUNT_MIDDLE_IDS: ReadonlySet<MiddleColumnId> = new Set([
  'row_count',
  'payable_line_count',
  'expected_no_commission_line_count',
  'zero_value_line_count',
  'review_line_count',
  'unconfigured_paid_staff_line_count',
  'derived_staff_paid_id',
])

/** Middle columns where body text truncates with ellipsis + native title tooltip. */
const TRUNCATE_WITH_TITLE_IDS: ReadonlySet<MiddleColumnId> = new Set([
  'work_performed_by',
  'derived_staff_paid_full_name',
  'derived_staff_paid_remuneration_plan',
  'location',
])

function sortAlignForMiddleColumn(id: MiddleColumnId): 'left' | 'right' {
  return CURRENCY_MIDDLE_IDS.has(id) ? 'right' : 'left'
}

function thClassForMiddleColumn(id: MiddleColumnId): string {
  const parts: string[] = []
  if (CURRENCY_MIDDLE_IDS.has(id)) {
    parts.push('w-[1%]', 'min-w-[5rem]', 'whitespace-nowrap', 'text-right')
  }
  if (id === 'pay_week_end') {
    parts.push('w-[1%]', 'min-w-0', 'max-w-[6rem]', 'whitespace-nowrap')
  }
  if (id === 'work_performed_by') {
    // Flexible text column: cap width so it does not leave a wide empty band; no w-[1%] so width tracks content up to max.
    parts.push('min-w-0', 'max-w-[13rem]', 'sm:max-w-[15rem]', 'lg:max-w-[17rem]')
  }
  if (id === 'derived_staff_paid_full_name') {
    parts.push('w-[1%]', 'min-w-0', 'max-w-[7rem]', 'sm:max-w-[8.5rem]')
  }
  if (id === 'derived_staff_paid_remuneration_plan') {
    parts.push('w-[1%]', 'min-w-0', 'max-w-[6rem]', 'sm:max-w-[6.75rem]')
  }
  if (id === 'location') {
    parts.push('w-[1%]', 'min-w-0', 'max-w-[7rem]', 'sm:max-w-[8rem]')
  }
  if (NUMERIC_COUNT_MIDDLE_IDS.has(id)) {
    parts.push('whitespace-nowrap')
  }
  return parts.join(' ')
}

function tdClassForMiddleColumn(id: MiddleColumnId): string {
  const parts: string[] = []
  if (CURRENCY_MIDDLE_IDS.has(id)) {
    parts.push('w-[1%]', 'min-w-[5rem]', 'whitespace-nowrap', 'text-right', 'tabular-nums')
  }
  if (id === 'pay_week_end') {
    parts.push('w-[1%]', 'min-w-0', 'max-w-[6rem]', 'whitespace-nowrap')
  }
  if (id === 'work_performed_by') {
    parts.push('min-w-0', 'max-w-[13rem]', 'sm:max-w-[15rem]', 'lg:max-w-[17rem]')
  }
  if (id === 'derived_staff_paid_full_name') {
    parts.push('w-[1%]', 'min-w-0', 'max-w-[7rem]', 'sm:max-w-[8.5rem]')
  }
  if (id === 'derived_staff_paid_remuneration_plan') {
    parts.push('w-[1%]', 'min-w-0', 'max-w-[6rem]', 'sm:max-w-[6.75rem]')
  }
  if (id === 'location') {
    parts.push('w-[1%]', 'min-w-0', 'max-w-[7rem]', 'sm:max-w-[8rem]')
  }
  if (NUMERIC_COUNT_MIDDLE_IDS.has(id)) {
    parts.push('whitespace-nowrap', 'tabular-nums')
  }
  if (
    !CURRENCY_MIDDLE_IDS.has(id) &&
    id !== 'pay_week_end' &&
    !NUMERIC_COUNT_MIDDLE_IDS.has(id) &&
    !TRUNCATE_WITH_TITLE_IDS.has(id)
  ) {
    parts.push('break-words')
  }
  return parts.join(' ')
}

function isDateLikeKey(rowKey: string): boolean {
  if (rowKey === 'pay_week_start') return false
  if (rowKey === 'pay_week_end' || rowKey === 'pay_date') return true
  if (rowKey.includes('_date') || rowKey.endsWith('_at')) return true
  return rowKey.includes('week') && rowKey.includes('start')
}

function Cell({
  rowKey,
  value,
  middleColumnId,
  workPerformedBySelfMatchNames,
}: {
  rowKey: string
  value: unknown
  middleColumnId?: MiddleColumnId
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
  if (isDateLikeKey(rowKey)) {
    return <span>{formatShortDate(String(value))}</span>
  }
  if (
    middleColumnId &&
    TRUNCATE_WITH_TITLE_IDS.has(middleColumnId) &&
    typeof value !== 'object'
  ) {
    let text = formatScalarText(value)
    if (text === '') return <span className="text-slate-400">—</span>
    if (
      middleColumnId === 'work_performed_by' &&
      workPerformedBySelfMatchNames != null &&
      workPerformedBySelfMatchNames.length > 0
    ) {
      text = prioritizeSelfInWorkPerformedByDisplay(
        text,
        workPerformedBySelfMatchNames,
      )
    }
    return (
      <span className="block min-w-0 truncate whitespace-nowrap" title={text}>
        {text}
      </span>
    )
  }
  if (typeof value === 'object' && value !== null) {
    return (
      <span className="font-mono text-xs">{JSON.stringify(value)}</span>
    )
  }
  const text = formatScalarText(value)
  return <span>{text === '' ? '—' : text}</span>
}

function stableSummaryRowKey(
  row: WeeklyCommissionSummaryRow,
  index: number,
): string {
  const week =
    row.pay_week_start != null && String(row.pay_week_start).trim() !== ''
      ? String(row.pay_week_start).trim()
      : 'noweek'
  const loc =
    row.location_id != null && String(row.location_id).trim() !== ''
      ? String(row.location_id).trim()
      : 'noloc'
  return `${week}-${loc}-${index}`
}

const DND_TYPE = 'application/x-payroll-middle-column'

export function WeeklySummaryTable({
  rows,
  tableStructureSample = null,
  emptyBodyMessage,
  toolbarDataSources,
  toolbarDateRange,
  forceHiddenColumnIds,
  showColumnPicker = true,
  columnLabelOverrides,
  mobileHiddenColumnIds,
  mobileColumnLabelOverrides,
  mobileDetailLabel,
  workPerformedBySelfMatchNames,
}: WeeklySummaryTableProps) {
  const { prefs, setPrefs, reset } = usePayrollSummaryColumnPreferences()
  const [previewSummaryRow, setPreviewSummaryRow] =
    useState<WeeklyCommissionSummaryRow | null>(null)
  const [draggingId, setDraggingId] = useState<MiddleColumnId | null>(null)
  const [dropTargetId, setDropTargetId] = useState<MiddleColumnId | null>(null)
  const [summarySort, setSummarySort] = useState<ColumnSortState>(null)

  const sample = rows[0] ?? tableStructureSample ?? null

  const displayRows = useMemo(
    () => sortStylistCommissionSummaryRows(rows, summarySort),
    [rows, summarySort],
  )

  const visibleMiddle = useMemo(
    () =>
      sample
        ? visibleMiddleColumns(sample, prefs, forceHiddenColumnIds)
        : [],
    [sample, prefs, forceHiddenColumnIds],
  )

  const showToolbarRow =
    toolbarDataSources != null ||
    toolbarDateRange != null ||
    showColumnPicker === true

  function onDragStart(e: React.DragEvent, id: MiddleColumnId) {
    e.dataTransfer.setData(DND_TYPE, id)
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
      e.dataTransfer.getData(DND_TYPE) || e.dataTransfer.getData('text/plain')
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

  const colSpanEmpty = 1 + visibleMiddle.length + 1

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
        <table className="w-full min-w-0 border-collapse text-left text-sm">
          <thead className="sticky top-0 z-20 bg-slate-50 shadow-[0_1px_0_0_rgb(226_232_240)]">
            <tr>
              {/* Start-of-week is now the leftmost (and sticky) column;
                  the previous separate Pay Week long-format header was
                  removed as part of the My Sales redesign. */}
              <th
                scope="col"
                className={`${thBase} sticky left-0 z-30 w-[1%] min-w-0 max-w-[5.5rem] whitespace-nowrap bg-slate-50`}
              >
                <TableColumnSortHeader
                  label="Start of week"
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
                const mobileHidden = mobileHiddenColumnIds?.has(id) ?? false
                const desktopLabel =
                  columnLabelOverrides?.[id] ?? COLUMN_LABEL[id]
                const mobileLabel = mobileColumnLabelOverrides?.[id]
                const thExtra = thClassForMiddleColumn(id)
                const headerLabelGrows =
                  id !== 'work_performed_by' &&
                  id !== 'derived_staff_paid_remuneration_plan'
                return (
                  <th
                    key={k}
                    scope="col"
                    className={`${thBase} ${thExtra} ${
                      mobileHidden ? 'hidden lg:table-cell' : ''
                    }`}
                  >
                    <div className="flex min-w-0 items-start gap-0.5">
                      <div className={headerLabelGrows ? 'min-w-0 flex-1' : 'min-w-0'}>
                        <TableColumnSortHeader
                          label={desktopLabel}
                          columnKey={k}
                          sortState={summarySort}
                          onSortChange={setSummarySort}
                          mobileLabel={mobileLabel ?? undefined}
                          wrapLabel={!CURRENCY_MIDDLE_IDS.has(id)}
                          align={sortAlignForMiddleColumn(id)}
                          className={
                            headerLabelGrows ? '' : '!w-auto max-w-full min-w-0'
                          }
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
              <th
                scope="col"
                className={`${thBase} w-[1%] min-w-0 max-w-[5.25rem] whitespace-nowrap`}
              >
                {mobileDetailLabel != null ? (
                  <>
                    <span className="lg:hidden">{mobileDetailLabel}</span>
                    <span className="hidden lg:inline">Detail</span>
                  </>
                ) : (
                  'Detail'
                )}
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
              const rowKey = stableSummaryRowKey(row, idx)
              return (
                <tr
                  key={rowKey}
                  className="group border-b border-slate-100 odd:bg-white even:bg-slate-50/90 hover:bg-violet-50/60"
                >
                  <td
                    className={`${tdBase} sticky left-0 z-10 w-[1%] min-w-0 max-w-[5.5rem] whitespace-nowrap border-slate-100 font-medium ${
                      idx % 2 === 0 ? 'bg-white' : 'bg-slate-50/90'
                    } group-hover:bg-violet-50/60`}
                  >
                    {weekStart ? (
                      <span>{formatShortDate(row.pay_week_start)}</span>
                    ) : (
                      <span className="text-slate-400">—</span>
                    )}
                  </td>
                  {visibleMiddle.map(({ id, rowKey: k }) => {
                    const mobileHidden =
                      mobileHiddenColumnIds?.has(id) ?? false
                    const tdExtra = tdClassForMiddleColumn(id)
                    return (
                      <td
                        key={k}
                        className={`${tdBase} ${tdExtra} ${
                          mobileHidden ? 'hidden lg:table-cell' : ''
                        }`}
                      >
                        <Cell
                          rowKey={k}
                          value={row[k as keyof WeeklyCommissionSummaryRow]}
                          middleColumnId={id}
                          workPerformedBySelfMatchNames={
                            workPerformedBySelfMatchNames
                          }
                        />
                      </td>
                    )
                  })}
                  <td
                    className={`${tdBase} w-[1%] min-w-0 max-w-[5.25rem] whitespace-nowrap`}
                  >
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
