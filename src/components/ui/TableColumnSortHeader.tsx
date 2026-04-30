import type { DragEvent } from 'react'

import type { ColumnSortState } from '@/lib/tableSort'
import { nextColumnSortState } from '@/lib/tableSort'

type Align = 'left' | 'right'

export function TableColumnSortHeader({
  label,
  columnKey,
  sortState,
  onSortChange,
  align = 'left',
  className = '',
  mobileLabel,
  /** When true, header text wraps instead of truncating (e.g. Sales Summary). */
  wrapLabel = false,
}: {
  label: string
  columnKey: string
  sortState: ColumnSortState
  onSortChange: (next: ColumnSortState) => void
  align?: Align
  className?: string
  mobileLabel?: string | null
  wrapLabel?: boolean
}) {
  const active = sortState != null && sortState.key === columnKey
  const dir = active ? sortState.dir : null
  const justify = align === 'right' ? 'justify-end' : 'justify-start'
  const textAlign = align === 'right' ? 'text-right' : 'text-left'

  return (
    <button
      type="button"
      className={`group inline-flex w-full min-w-0 ${wrapLabel ? 'items-start' : 'items-center'} gap-1 rounded px-0.5 py-0.5 ${justify} ${textAlign} text-inherit hover:bg-slate-100/90 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-400 focus-visible:ring-offset-1 ${className}`}
      onClick={() => onSortChange(nextColumnSortState(sortState, columnKey))}
      aria-sort={
        dir === 'asc' ? 'ascending' : dir === 'desc' ? 'descending' : 'none'
      }
    >
      <span
        className={`inline-flex shrink-0 flex-col text-[0.55rem] leading-[0.6rem] text-slate-300 transition group-hover:text-slate-400 ${wrapLabel ? 'mt-0.5' : ''}`}
        aria-hidden
      >
        <span className={dir === 'asc' ? 'text-violet-600' : ''}>▲</span>
        <span className={`-mt-px ${dir === 'desc' ? 'text-violet-600' : ''}`}>▼</span>
      </span>
      <span
        className={
          wrapLabel
            ? 'min-w-0 whitespace-normal break-words text-left font-inherit leading-snug'
            : 'min-w-0 truncate font-inherit'
        }
      >
        {mobileLabel != null ? (
          <>
            <span className="lg:hidden">{mobileLabel}</span>
            <span className="hidden lg:inline">{label}</span>
          </>
        ) : (
          label
        )}
      </span>
    </button>
  )
}

/** Drag handle for column reorder (middle columns only). */
export function ColumnReorderHandle({
  dragging,
  isDropTarget,
  onDragStart,
  onDragOver,
  onDrop,
  onDragEnd,
  title = 'Drag to reorder column',
}: {
  dragging: boolean
  isDropTarget: boolean
  onDragStart: (e: DragEvent) => void
  onDragOver: (e: DragEvent) => void
  onDrop: (e: DragEvent) => void
  onDragEnd: () => void
  title?: string
}) {
  return (
    <span
      role="button"
      tabIndex={0}
      draggable
      title={title}
      onDragStart={onDragStart}
      onDragOver={onDragOver}
      onDrop={onDrop}
      onDragEnd={onDragEnd}
      className={`shrink-0 cursor-grab select-none rounded px-0.5 text-slate-400 active:cursor-grabbing ${
        dragging ? 'opacity-50' : ''
      } ${isDropTarget ? 'bg-violet-100/90 ring-1 ring-inset ring-violet-300' : ''}`}
      aria-grabbed={dragging}
    >
      <span className="text-xs leading-none tracking-tighter" aria-hidden>
        ⋮⋮
      </span>
    </span>
  )
}
