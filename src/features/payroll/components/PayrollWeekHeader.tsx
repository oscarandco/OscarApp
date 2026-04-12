import { Link } from 'react-router-dom'

import { PayWeekBadge } from '@/features/payroll/components/PayWeekBadge'
import { isEmptyish } from '@/lib/cellValue'
import { formatDateLabel, formatShortDate } from '@/lib/formatters'

type PayrollWeekHeaderProps = {
  payWeekStart: string
  payWeekEnd?: string | null
  payDate?: string | null
  backTo?: string
  backLabel?: string
}

export function PayrollWeekHeader({
  payWeekStart,
  payWeekEnd,
  payDate,
  backTo = '/app/payroll',
  backLabel = '← Back to weekly summary',
}: PayrollWeekHeaderProps) {
  const startTrim = payWeekStart.trim()

  return (
    <div
      className="mb-6 border-b border-slate-200 pb-5"
      data-testid="payroll-week-header"
    >
      <Link
        to={backTo}
        className="inline-flex text-sm font-medium text-violet-700 hover:text-violet-900"
      >
        {backLabel}
      </Link>
      <div className="mt-4 flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0 flex-1">
          <h2 className="text-xl font-semibold tracking-tight text-slate-900">
            Week of {formatDateLabel(startTrim || undefined)}
          </h2>
          <dl className="mt-3 grid gap-3 text-sm text-slate-600 sm:grid-cols-2 lg:grid-cols-3">
            <div>
              <dt className="text-xs font-medium uppercase tracking-wide text-slate-500">
                Pay week start
              </dt>
              <dd className="font-mono text-slate-800">
                {startTrim !== '' ? startTrim : '—'}
              </dd>
            </div>
            {!isEmptyish(payWeekEnd) ? (
              <div>
                <dt className="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Pay week end
                </dt>
                <dd>{formatShortDate(payWeekEnd)}</dd>
              </div>
            ) : null}
            {!isEmptyish(payDate) ? (
              <div>
                <dt className="text-xs font-medium uppercase tracking-wide text-slate-500">
                  Pay date
                </dt>
                <dd>{formatShortDate(payDate)}</dd>
              </div>
            ) : null}
          </dl>
        </div>
        {startTrim !== '' ? (
          <PayWeekBadge payWeekStartIso={startTrim} className="shrink-0" />
        ) : null}
      </div>
    </div>
  )
}
