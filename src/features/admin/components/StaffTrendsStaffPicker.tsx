import { useMemo, useState } from 'react'

export type StaffPickerOption = {
  id: string
  label: string
}

type Props = {
  options: StaffPickerOption[]
  selectedIds: string[]
  onChange: (ids: string[]) => void
  /** Cap how many can be selected at once. */
  maxSelected?: number
}

/**
 * Compact multi-select for staff members. Inline panel with search and a
 * scrolling checkbox list. Built locally rather than depending on a
 * combobox library because the app has none today.
 */
export function StaffTrendsStaffPicker({
  options,
  selectedIds,
  onChange,
  maxSelected = 12,
}: Props) {
  const [search, setSearch] = useState('')

  const selectedSet = useMemo(() => new Set(selectedIds), [selectedIds])

  const filtered = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (q === '') return options
    return options.filter((o) => o.label.toLowerCase().includes(q))
  }, [options, search])

  function toggle(id: string) {
    if (selectedSet.has(id)) {
      onChange(selectedIds.filter((x) => x !== id))
      return
    }
    if (selectedIds.length >= maxSelected) return
    onChange([...selectedIds, id])
  }

  function selectAll() {
    const ids = filtered.slice(0, maxSelected).map((o) => o.id)
    onChange(ids)
  }

  function clearAll() {
    onChange([])
  }

  const atLimit = selectedIds.length >= maxSelected

  return (
    <div className="flex flex-col gap-2">
      <div className="flex items-center justify-between gap-2">
        <label
          htmlFor="staff-trends-staff-search"
          className="text-sm font-medium text-slate-700"
        >
          Staff members
        </label>
        <div className="flex items-center gap-3 text-xs text-slate-500">
          <span data-testid="staff-trends-selected-count">
            {selectedIds.length} selected
          </span>
          <button
            type="button"
            className="rounded-md px-2 py-1 text-violet-700 hover:bg-violet-50"
            onClick={selectAll}
            disabled={filtered.length === 0}
          >
            Select shown
          </button>
          <button
            type="button"
            className="rounded-md px-2 py-1 text-slate-600 hover:bg-slate-100"
            onClick={clearAll}
            disabled={selectedIds.length === 0}
          >
            Clear
          </button>
        </div>
      </div>

      <input
        id="staff-trends-staff-search"
        type="search"
        placeholder="Search staff..."
        value={search}
        onChange={(e) => setSearch(e.target.value)}
        className="w-full rounded-md border border-slate-200 px-3 py-1.5 text-sm focus:border-violet-300 focus:outline-none focus:ring-2 focus:ring-violet-200"
      />

      <div
        className="max-h-56 overflow-y-auto rounded-md border border-slate-200 bg-white"
        data-testid="staff-trends-staff-list"
      >
        {filtered.length === 0 ? (
          <p className="px-3 py-2 text-sm text-slate-500">
            No staff match this search.
          </p>
        ) : (
          <ul className="divide-y divide-slate-100">
            {filtered.map((o) => {
              const checked = selectedSet.has(o.id)
              const disabled = !checked && atLimit
              return (
                <li key={o.id}>
                  <label
                    className={[
                      'flex cursor-pointer items-center gap-2 px-3 py-1.5 text-sm',
                      disabled
                        ? 'cursor-not-allowed text-slate-400'
                        : 'text-slate-700 hover:bg-slate-50',
                    ].join(' ')}
                  >
                    <input
                      type="checkbox"
                      className="h-4 w-4 rounded border-slate-300 text-violet-600 focus:ring-violet-300"
                      checked={checked}
                      disabled={disabled}
                      onChange={() => toggle(o.id)}
                    />
                    <span className="truncate">{o.label}</span>
                  </label>
                </li>
              )
            })}
          </ul>
        )}
      </div>

      {atLimit ? (
        <p className="text-xs text-amber-700">
          Showing up to {maxSelected} staff at a time keeps the chart
          readable. Clear one to add another.
        </p>
      ) : null}
    </div>
  )
}
