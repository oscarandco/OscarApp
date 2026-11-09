import { Link } from 'react-router-dom'

import { useCanViewPage } from '@/features/access/pageAccess'
import { isCommissionCostReadinessError } from '@/lib/queryError'

type ErrorStateProps = {
  title?: string
  message?: string
  error?: Error | null
  onRetry?: () => void
  fullPage?: boolean
  testId?: string
}

function CommissionCostResolutionLink() {
  const canReviewPayroll = useCanViewPage('weekly_payroll')
  return canReviewPayroll ? <Link className="mt-3 block text-sm font-medium text-violet-800 underline" to="/app/admin/weekly-payroll">Review costs in Weekly payroll</Link> : null
}

export function ErrorState({
  title = 'Something went wrong',
  message,
  error,
  onRetry,
  fullPage = false,
  testId,
}: ErrorStateProps) {
  const detail = message ?? error?.message ?? 'Please try again.'
  const awaitingCosts = isCommissionCostReadinessError(detail) || isCommissionCostReadinessError(error)

  const inner = (
    <div
      className="mx-auto max-w-md rounded-lg border border-red-200 bg-red-50 px-4 py-6 text-center"
      role="alert"
      data-testid={testId}
    >
      <h2 className="text-base font-semibold text-red-900">{awaitingCosts ? 'Commission awaiting product costs' : title}</h2>
      <p className="mt-2 text-sm text-red-800">{awaitingCosts ? 'Commission totals for this report are unavailable until the required service product costs are configured. An admin can resolve them in Weekly payroll, then retry this report.' : detail}</p>
      {awaitingCosts ? <CommissionCostResolutionLink /> : null}
      {onRetry ? (
        <button
          type="button"
          onClick={onRetry}
          className="mt-4 rounded-md bg-red-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-800"
        >
          Retry
        </button>
      ) : null}
    </div>
  )

  if (fullPage) {
    return (
      <div className="flex min-h-dvh items-center justify-center bg-slate-50 px-4">
        {inner}
      </div>
    )
  }

  return inner
}
