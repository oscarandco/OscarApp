import { useEffect, useMemo, useState, type FormEvent } from 'react'

/**
 * Modal shown by Staff Admin whenever a save touches any of the effective-
 * dated role/pay fields (primary_role, secondary_roles, employment_type,
 * remuneration_plan, fte, primary_location_id).
 *
 * The admin enters an effective_start_date (default = today) and an
 * optional reason. On confirm, the parent calls
 * `apply_staff_role_assignment` via the staff API helper.
 *
 * This component is purely a form container: no data fetching, no
 * mutation logic. The caller owns the change list (`pendingChanges`),
 * which the modal renders as a read-only preview for the admin.
 */

export type RoleAssignmentChange = {
  /** Display label, e.g. "Primary role". */
  label: string
  /** Previous value rendered in the "from" cell. Empty / null shows as "—". */
  oldValue: string | null | undefined
  /** New value rendered in the "to" cell. */
  newValue: string | null | undefined
}

type ApplyRoleAssignmentModalProps = {
  open: boolean
  /** Display name (or full name) of the staff member being edited. */
  staffDisplayName: string
  /** The fields that are about to change. Used for the preview list. */
  pendingChanges: RoleAssignmentChange[]
  /** Disables form controls + buttons while the parent's mutation is running. */
  submitting?: boolean
  /** Error message from a failed apply, rendered in the modal footer. */
  submitError?: string | null
  onClose: () => void
  onConfirm: (values: { effectiveDate: string; reason: string }) => void
}

function todayIso(): string {
  // Local ISO date (YYYY-MM-DD) avoids the UTC drift of toISOString().
  const d = new Date()
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

function displayValue(v: string | null | undefined): string {
  const s = (v ?? '').trim()
  return s === '' ? '—' : s
}

export function ApplyRoleAssignmentModal({
  open,
  staffDisplayName,
  pendingChanges,
  submitting = false,
  submitError = null,
  onClose,
  onConfirm,
}: ApplyRoleAssignmentModalProps) {
  const [effectiveDate, setEffectiveDate] = useState<string>(todayIso())
  const [reason, setReason] = useState<string>('')

  // Reset form whenever the modal is (re-)opened.
  useEffect(() => {
    if (open) {
      setEffectiveDate(todayIso())
      setReason('')
    }
  }, [open])

  useEffect(() => {
    if (!open) return
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape' && !submitting) onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose, submitting])

  const dateValid = useMemo(() => {
    if (!effectiveDate) return false
    // <input type="date"> already gives us a YYYY-MM-DD string when set.
    return /^\d{4}-\d{2}-\d{2}$/.test(effectiveDate)
  }, [effectiveDate])

  function handleSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault()
    if (!dateValid || submitting) return
    onConfirm({ effectiveDate, reason: reason.trim() })
  }

  if (!open) return null

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="apply-role-assignment-title"
      data-testid="apply-role-assignment-modal"
      onClick={() => {
        if (!submitting) onClose()
      }}
    >
      <div
        className="w-full max-w-lg rounded-lg border border-slate-200 bg-white p-5 shadow-lg"
        onClick={(e) => e.stopPropagation()}
      >
        <h2
          id="apply-role-assignment-title"
          className="text-lg font-semibold text-slate-900"
        >
          Apply role and pay change
        </h2>
        <p className="mt-1 text-sm text-slate-600">
          {staffDisplayName ? (
            <>
              For <span className="font-medium text-slate-800">{staffDisplayName}</span>.{' '}
            </>
          ) : null}
          This change affects payroll and commission calculations from the
          effective date forward. Previous periods will continue to use the
          earlier staff history unless you backdate the effective date.
        </p>

        <form className="mt-4 space-y-4" onSubmit={handleSubmit}>
          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div>
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="apply-role-assignment-date"
              >
                Effective from date <span className="text-red-600">*</span>
              </label>
              <input
                id="apply-role-assignment-date"
                type="date"
                required
                value={effectiveDate}
                onChange={(e) => setEffectiveDate(e.target.value)}
                disabled={submitting}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500 disabled:bg-slate-50"
              />
              <p className="mt-1 text-xs text-slate-500">
                Default is today. Backdate to apply the change retroactively.
              </p>
            </div>
            <div>
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="apply-role-assignment-reason"
              >
                Reason
              </label>
              <input
                id="apply-role-assignment-reason"
                type="text"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                placeholder="Optional, e.g. Promoted to Junior Stylist"
                disabled={submitting}
                maxLength={200}
                className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500 disabled:bg-slate-50"
              />
              <p className="mt-1 text-xs text-slate-500">
                Stored on the assignment for audit. Recommended.
              </p>
            </div>
          </div>

          {pendingChanges.length > 0 ? (
            <div className="rounded-lg border border-slate-200 bg-slate-50/70 p-3">
              <h3 className="text-xs font-semibold uppercase tracking-wide text-slate-600">
                Changes in this update
              </h3>
              <ul className="mt-2 divide-y divide-slate-200">
                {pendingChanges.map((c) => (
                  <li
                    key={c.label}
                    className="grid grid-cols-[8rem_1fr_1fr] items-center gap-2 py-1.5 text-sm"
                  >
                    <span className="font-medium text-slate-800">{c.label}</span>
                    <span className="truncate text-slate-500" title={displayValue(c.oldValue)}>
                      {displayValue(c.oldValue)}
                    </span>
                    <span className="truncate text-slate-900" title={displayValue(c.newValue)}>
                      → {displayValue(c.newValue)}
                    </span>
                  </li>
                ))}
              </ul>
            </div>
          ) : null}

          {submitError ? (
            <p className="text-sm text-red-600" role="alert">
              {submitError}
            </p>
          ) : null}

          <div className="flex justify-end gap-2 pt-1">
            <button
              type="button"
              onClick={onClose}
              disabled={submitting}
              className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-50"
              data-testid="apply-role-assignment-cancel"
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={!dateValid || submitting}
              className="rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1 disabled:cursor-not-allowed disabled:opacity-50"
              data-testid="apply-role-assignment-confirm"
            >
              {submitting ? 'Applying…' : 'Apply change'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
