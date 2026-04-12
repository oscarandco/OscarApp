import { formatWeekBadgeLabel } from '@/lib/formatters'

type PayWeekBadgeProps = {
  /** Pay week start (typically `YYYY-MM-DD`). */
  payWeekStartIso: string
  className?: string
}

/**
 * Compact chip showing the selected payroll week for detail headers.
 */
export function PayWeekBadge({ payWeekStartIso, className = '' }: PayWeekBadgeProps) {
  const trimmed = payWeekStartIso.trim()
  const label = formatWeekBadgeLabel(trimmed || undefined)

  return (
    <div
      className={`inline-flex flex-col rounded-md border border-slate-200 bg-slate-50 px-2.5 py-1 text-left ${className}`}
      data-testid="pay-week-badge"
    >
      <span className="text-[10px] font-semibold uppercase tracking-wide text-slate-500">
        Pay week
      </span>
      <span className="font-mono text-sm font-semibold tabular-nums text-slate-900">
        {trimmed !== '' ? trimmed : '—'}
      </span>
      {label !== '—' ? (
        <span className="text-xs text-slate-600">{label}</span>
      ) : null}
    </div>
  )
}
