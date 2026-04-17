import { type FormEvent, useEffect, useState } from 'react'

type AddSectionModalProps = {
  open: boolean
  nextDisplayOrder: number
  onClose: () => void
  onAdd: (input: {
    name: string
    summaryLabel: string
    displayOrder: number
    active: boolean
  }) => void
}

export function AddSectionModal({
  open,
  nextDisplayOrder,
  onClose,
  onAdd,
}: AddSectionModalProps) {
  const [name, setName] = useState('')
  const [summaryLabel, setSummaryLabel] = useState('')
  const [displayOrder, setDisplayOrder] = useState<string>(String(nextDisplayOrder))
  const [active, setActive] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!open) return
    setName('')
    setSummaryLabel('')
    setDisplayOrder(String(nextDisplayOrder))
    setActive(true)
    setError(null)
  }, [open, nextDisplayOrder])

  useEffect(() => {
    if (!open) return
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) return null

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    const trimmedName = name.trim()
    if (trimmedName === '') {
      setError('Section Name is required.')
      return
    }
    const order = Number(displayOrder)
    if (!Number.isFinite(order)) {
      setError('Display Order must be a number.')
      return
    }
    onAdd({
      name: trimmedName,
      summaryLabel: summaryLabel.trim() || trimmedName,
      displayOrder: Math.trunc(order),
      active,
    })
    onClose()
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="add-section-title"
      onClick={onClose}
    >
      <div
        className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 id="add-section-title" className="text-lg font-semibold text-slate-900">
          Add Section
        </h2>
        <p className="mt-1 text-sm text-slate-600">
          Create a new quote section. You can add services once it&apos;s created.
        </p>
        <form onSubmit={onSubmit} className="mt-4 space-y-4">
          <div>
            <label
              htmlFor="add-section-name"
              className="block text-sm font-medium text-slate-700"
            >
              Section Name <span className="text-rose-600">*</span>
            </label>
            <input
              id="add-section-name"
              type="text"
              autoFocus
              required
              value={name}
              onChange={(e) => setName(e.target.value)}
              className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
              data-testid="add-section-name"
            />
          </div>
          <div>
            <label
              htmlFor="add-section-summary-label"
              className="block text-sm font-medium text-slate-700"
            >
              Summary Label
            </label>
            <input
              id="add-section-summary-label"
              type="text"
              value={summaryLabel}
              onChange={(e) => setSummaryLabel(e.target.value)}
              className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
              placeholder="Defaults to Section Name"
              data-testid="add-section-summary-label"
            />
            <p className="mt-1 text-xs text-slate-500">
              Shown in the saved quote summary footer. Sections that share a label
              are grouped together.
            </p>
          </div>
          <div className="grid grid-cols-2 gap-4">
            <div>
              <label
                htmlFor="add-section-display-order"
                className="block text-sm font-medium text-slate-700"
              >
                Display Order
              </label>
              <input
                id="add-section-display-order"
                type="number"
                value={displayOrder}
                onChange={(e) => setDisplayOrder(e.target.value)}
                className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
                data-testid="add-section-display-order"
              />
            </div>
            <div className="flex items-end">
              <label className="inline-flex items-center gap-2 rounded-md border border-slate-200 bg-white px-3 py-2 text-sm text-slate-800">
                <input
                  type="checkbox"
                  checked={active}
                  onChange={(e) => setActive(e.target.checked)}
                  className="h-4 w-4 rounded border-slate-300 text-violet-600 focus:ring-violet-500"
                  data-testid="add-section-active"
                />
                Active
              </label>
            </div>
          </div>
          {error ? (
            <p
              className="rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
              role="alert"
            >
              {error}
            </p>
          ) : null}
          <div className="flex justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
            >
              Cancel
            </button>
            <button
              type="submit"
              className="rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1"
              data-testid="add-section-submit"
            >
              Add Section
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
