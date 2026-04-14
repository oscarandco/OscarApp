import { useEffect, useId, useRef, useState } from 'react'

import {
  LINE_COLUMN_LABEL,
  LINE_LOCKED_VISIBLE,
  type LineColumnId,
  type LineTablePreferences,
} from '@/features/payroll/payrollLineTableColumns'

type PayrollLineColumnPickerProps = {
  prefs: LineTablePreferences
  onChange: (next: LineTablePreferences) => void
  onReset: () => void
}

function moveId(order: LineColumnId[], id: LineColumnId, dir: -1 | 1): LineColumnId[] {
  const i = order.indexOf(id)
  if (i < 0) return order
  const j = i + dir
  if (j < 0 || j >= order.length) return order
  const next = [...order]
  ;[next[i], next[j]] = [next[j], next[i]]
  return next
}

export function PayrollLineColumnPicker({
  prefs,
  onChange,
  onReset,
}: PayrollLineColumnPickerProps) {
  const panelId = useId()
  const [open, setOpen] = useState(false)
  const wrapRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    if (!open) return
    function onDocMouseDown(e: MouseEvent) {
      if (wrapRef.current?.contains(e.target as Node)) return
      setOpen(false)
    }
    document.addEventListener('mousedown', onDocMouseDown)
    return () => document.removeEventListener('mousedown', onDocMouseDown)
  }, [open])

  const hiddenSet = new Set(prefs.hidden)

  function toggle(id: LineColumnId) {
    if (LINE_LOCKED_VISIBLE.has(id)) return
    const nextHidden = new Set(prefs.hidden)
    if (nextHidden.has(id)) nextHidden.delete(id)
    else nextHidden.add(id)
    onChange({
      ...prefs,
      hidden: [...nextHidden],
    })
  }

  function move(id: LineColumnId, dir: -1 | 1) {
    onChange({
      ...prefs,
      order: moveId(prefs.order, id, dir),
    })
  }

  return (
    <div className="relative" ref={wrapRef}>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        className="rounded-md border border-slate-200 bg-white px-3 py-1.5 text-sm font-medium text-slate-700 shadow-sm hover:bg-slate-50"
        aria-expanded={open}
        aria-controls={panelId}
        data-testid="payroll-line-column-picker-trigger"
      >
        Columns
      </button>
      {open ? (
        <div
          id={panelId}
          className="absolute right-0 z-40 mt-1 w-[min(100vw-2rem,22rem)] rounded-lg border border-slate-200 bg-white p-3 text-sm shadow-lg"
          data-testid="payroll-line-column-picker-panel"
        >
          <p className="mb-2 text-xs text-slate-500">
            Invoice stays visible. Toggle other columns or reorder with the arrows.
          </p>
          <ul className="max-h-[min(60vh,20rem)] space-y-1 overflow-y-auto">
            {prefs.order.map((id) => {
              const locked = LINE_LOCKED_VISIBLE.has(id)
              const visible = locked || !hiddenSet.has(id)
              return (
                <li
                  key={id}
                  className="flex items-center gap-2 rounded px-1 py-0.5 hover:bg-slate-50"
                >
                  <label className="flex min-w-0 flex-1 cursor-pointer items-center gap-2">
                    <input
                      type="checkbox"
                      checked={visible}
                      disabled={locked}
                      onChange={() => toggle(id)}
                      className="rounded border-slate-300"
                    />
                    <span className="truncate text-slate-800">
                      {LINE_COLUMN_LABEL[id]}
                      {locked ? (
                        <span className="ml-1 text-xs text-slate-400">(required)</span>
                      ) : null}
                    </span>
                  </label>
                  <span className="flex shrink-0 gap-0.5">
                    <button
                      type="button"
                      className="rounded border border-slate-200 px-1.5 py-0.5 text-xs text-slate-600 hover:bg-slate-100"
                      aria-label={`Move ${LINE_COLUMN_LABEL[id]} up`}
                      onClick={() => move(id, -1)}
                    >
                      ↑
                    </button>
                    <button
                      type="button"
                      className="rounded border border-slate-200 px-1.5 py-0.5 text-xs text-slate-600 hover:bg-slate-100"
                      aria-label={`Move ${LINE_COLUMN_LABEL[id]} down`}
                      onClick={() => move(id, 1)}
                    >
                      ↓
                    </button>
                  </span>
                </li>
              )
            })}
          </ul>
          <div className="mt-3 flex justify-end gap-2 border-t border-slate-100 pt-2">
            <button
              type="button"
              className="text-sm text-violet-700 hover:text-violet-900"
              onClick={() => {
                onReset()
                setOpen(false)
              }}
              data-testid="payroll-line-column-picker-reset"
            >
              Reset to default
            </button>
          </div>
        </div>
      ) : null}
    </div>
  )
}
