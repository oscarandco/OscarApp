import type { ReactNode } from 'react'
import { useMemo, useState } from 'react'
import { Link } from 'react-router-dom'

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
   * Renders to the left of the Columns control: date range + data
   * source lines (My Sales / Sales summary reporting toolbar).
   */
  toolbarBeforeColumns?: ReactNode
  /**
   * Middle column ids that must always be hidden, layered on top of
   * the user's saved column-picker preferences. Owned by the page so
   * role-based hides (Staff Paid, Potential Commission, Commission
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
}

// Mobile (`<sm`) gets noticeably tighter horizontal padding and a
// smaller per-column min-width so the visible columns sit closer
// together; the existing `sm:` upgrades restore the original desktop
// spacing untouched (px-4, min-w 6.5rem). Vertical padding (py-2.5)
// is preserved on both widths so row heights / tap targets do not
// change.
const thBase =
  'border-b border-slate-200 px-1.5 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-4 sm:py-3 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700'
const tdBase =
  'whitespace-nowrap px-1.5 py-2.5 text-slate-700 sm:px-4 sm:py-3 min-w-[4rem] sm:min-w-[6.5rem]'

function isDateLikeKey(rowKey: string): boolean {
  if (rowKey === 'pay_week_start') return false
  if (rowKey === 'pay_week_end' || rowKey === 'pay_date') return true
  if (rowKey.includes('_date') || rowKey.endsWith('_at')) return true
  return rowKey.includes('week') && rowKey.includes('start')
}

function Cell({
  rowKey,
  value,
}: {
  rowKey: string
  value: unknown
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
  toolbarBeforeColumns,
  forceHiddenColumnIds,
  showColumnPicker = true,
  columnLabelOverrides,
  mobileHiddenColumnIds,
  mobileColumnLabelOverrides,
  mobileDetailLabel,
}: WeeklySummaryTableProps) {
  const { prefs, setPrefs, reset } = usePayrollSummaryColumnPreferences()
  const [previewSummaryRow, setPreviewSummaryRow] =
    useState<WeeklyCommissionSummaryRow | null>(null)
  const [draggingId, setDraggingId] = useState<MiddleColumnId | null>(null)
  const [dropTargetId, setDropTargetId] = useState<MiddleColumnId | null>(null)

  const sample = rows[0] ?? tableStructureSample ?? null

  const visibleMiddle = useMemo(
    () =>
      sample
        ? visibleMiddleColumns(sample, prefs, forceHiddenColumnIds)
        : [],
    [sample, prefs, forceHiddenColumnIds],
  )

  const showToolbarRow =
    toolbarBeforeColumns != null || showColumnPicker === true

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
        <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between sm:gap-4">
          {toolbarBeforeColumns != null ? (
            <div className="flex min-w-0 flex-1 flex-col gap-3 md:flex-row md:items-start md:gap-6 lg:gap-8">
              {toolbarBeforeColumns}
            </div>
          ) : (
            <div className="min-w-0 flex-1" />
          )}
          {showColumnPicker ? (
            <div className="flex shrink-0 justify-start sm:justify-end sm:pt-0.5">
              <WeeklySummaryColumnPicker
                prefs={prefs}
                onChange={setPrefs}
                onReset={reset}
              />
            </div>
          ) : null}
        </div>
      ) : null}
      <TableScrollArea testId="weekly-summary-table">
        <table className="w-full border-collapse text-left text-sm sm:min-w-[760px]">
          <thead className="sticky top-0 z-20 bg-slate-50 shadow-[0_1px_0_0_rgb(226_232_240)]">
            <tr>
              {/* Start-of-week is now the leftmost (and sticky) column;
                  the previous separate Pay Week long-format header was
                  removed as part of the My Sales redesign. */}
              <th
                scope="col"
                className={`${thBase} sticky left-0 z-30 min-w-[5.25rem] bg-slate-50 sm:min-w-[8.5rem]`}
              >
                Start of week
              </th>
              {visibleMiddle.map(({ id, rowKey: k }) => {
                const isDragging = draggingId === id
                const isDropTarget =
                  dropTargetId === id && draggingId != null && draggingId !== id
                const mobileHidden = mobileHiddenColumnIds?.has(id) ?? false
                const desktopLabel =
                  columnLabelOverrides?.[id] ?? COLUMN_LABEL[id]
                const mobileLabel = mobileColumnLabelOverrides?.[id]
                return (
                  <th
                    key={k}
                    scope="col"
                    draggable
                    onDragStart={(e) => onDragStart(e, id)}
                    onDragOver={(e) => onDragOverCol(e, id)}
                    onDrop={(e) => onDropOnCol(e, id)}
                    onDragEnd={onDragEnd}
                    title="Drag to reorder column"
                    className={`${thBase} cursor-grab select-none active:cursor-grabbing ${
                      mobileHidden ? 'hidden lg:table-cell' : ''
                    } ${isDragging ? 'opacity-50' : ''} ${
                      isDropTarget
                        ? 'bg-violet-100/90 ring-1 ring-inset ring-violet-300'
                        : ''
                    }`}
                    aria-grabbed={isDragging}
                  >
                    {mobileLabel != null ? (
                      <>
                        <span className="lg:hidden">{mobileLabel}</span>
                        <span className="hidden lg:inline">{desktopLabel}</span>
                      </>
                    ) : (
                      desktopLabel
                    )}
                  </th>
                )
              })}
              <th scope="col" className={`${thBase} min-w-[3rem] sm:min-w-[5.5rem]`}>
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
            {rows.map((row, idx) => {
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
                    className={`${tdBase} sticky left-0 z-10 min-w-[5.25rem] border-slate-100 font-medium sm:min-w-[8.5rem] ${
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
                    return (
                      <td
                        key={k}
                        className={`${tdBase} ${
                          mobileHidden ? 'hidden lg:table-cell' : ''
                        }`}
                      >
                        <Cell
                          rowKey={k}
                          value={row[k as keyof WeeklyCommissionSummaryRow]}
                        />
                      </td>
                    )
                  })}
                  <td className={`${tdBase} min-w-[3rem] sm:min-w-[5.5rem]`}>
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
