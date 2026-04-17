import { useEffect } from 'react'

type ConfirmDialogTone = 'danger' | 'primary'

type ConfirmDialogProps = {
  open: boolean
  title: string
  description?: string
  confirmLabel?: string
  cancelLabel?: string
  tone?: ConfirmDialogTone
  onConfirm: () => void
  onClose: () => void
  testId?: string
}

/**
 * Lightweight, app-consistent confirmation dialog used anywhere we would
 * otherwise reach for `window.confirm`. Matches the styling used by
 * `AccessMappingFormModal` and the other admin modals.
 */
export function ConfirmDialog({
  open,
  title,
  description,
  confirmLabel = 'Confirm',
  cancelLabel = 'Cancel',
  tone = 'danger',
  onConfirm,
  onClose,
  testId,
}: ConfirmDialogProps) {
  useEffect(() => {
    if (!open) return
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  if (!open) return null

  const confirmClass =
    tone === 'danger'
      ? 'rounded-md bg-rose-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-rose-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-rose-500 focus-visible:ring-offset-1'
      : 'rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1'

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="confirm-dialog-title"
      data-testid={testId}
      onClick={onClose}
    >
      <div
        className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
        onClick={(e) => e.stopPropagation()}
      >
        <h2
          id="confirm-dialog-title"
          className="text-lg font-semibold text-slate-900"
        >
          {title}
        </h2>
        {description ? (
          <p className="mt-2 text-sm text-slate-600">{description}</p>
        ) : null}
        <div className="mt-5 flex justify-end gap-2">
          <button
            type="button"
            onClick={onClose}
            className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
            data-testid={testId ? `${testId}-cancel` : undefined}
          >
            {cancelLabel}
          </button>
          <button
            type="button"
            onClick={() => {
              onConfirm()
              onClose()
            }}
            className={confirmClass}
            data-testid={testId ? `${testId}-confirm` : undefined}
            autoFocus
          >
            {confirmLabel}
          </button>
        </div>
      </div>
    </div>
  )
}
