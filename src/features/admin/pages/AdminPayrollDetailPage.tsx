import { useMemo } from 'react'
import { useParams } from 'react-router-dom'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { AdminPayrollLineTable } from '@/features/admin/components/AdminPayrollLineTable'
import { PayrollWeekHeader } from '@/features/payroll/components/PayrollWeekHeader'
import { useAdminPayrollLinesWeekly } from '@/features/admin/hooks/useAdminPayrollLinesWeekly'
import { formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'
import { parsePayWeekRouteParam } from '@/lib/routeParams'

export function AdminPayrollDetailPage() {
  const { payWeekStart: rawParam } = useParams<{ payWeekStart: string }>()
  const parsed = parsePayWeekRouteParam(rawParam)
  const payWeekForQuery = parsed.kind === 'ok' ? parsed.value : undefined

  const { data, isLoading, isError, error, refetch } =
    useAdminPayrollLinesWeekly(payWeekForQuery)

  const context = useMemo(() => {
    const lines = data ?? []
    const first = lines[0]
    return {
      payWeekEnd: first?.pay_week_end ?? null,
      payDate: first?.pay_date ?? null,
    }
  }, [data])

  if (parsed.kind === 'missing') {
    return (
      <div data-testid="admin-detail-page">
        <ErrorState
          title="No pay week selected"
          message="Open this page from Admin weekly payroll using View lines on a row."
          testId="admin-detail-param-error"
        />
      </div>
    )
  }

  if (parsed.kind === 'invalid') {
    return (
      <div data-testid="admin-detail-page">
        <ErrorState
          title="Invalid pay week link"
          message={`${parsed.reason} (Received: ${parsed.rawDisplay})`}
          testId="admin-detail-param-error"
        />
      </div>
    )
  }

  const payWeekStart = parsed.value

  if (isLoading) {
    return (
      <div data-testid="admin-detail-page">
        <PayrollWeekHeader
          payWeekStart={payWeekStart}
          backTo="/app/admin/payroll"
          backLabel="← Back to admin weekly summary"
        />
        <LoadingState
          message="Loading admin line detail…"
          testId="admin-detail-loading"
        />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="admin-detail-page">
        <PayrollWeekHeader
          payWeekStart={payWeekStart}
          backTo="/app/admin/payroll"
          backLabel="← Back to admin weekly summary"
        />
        <ErrorState
          title="Could not load admin lines for this week"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="admin-detail-error"
        />
      </div>
    )
  }

  const lines = data ?? []
  const weekLabel = formatShortDate(payWeekStart)

  return (
    <div data-testid="admin-detail-page" className="max-w-[100vw]">
      <PayrollWeekHeader
        payWeekStart={payWeekStart}
        payWeekEnd={context.payWeekEnd}
        payDate={context.payDate}
        backTo="/app/admin/payroll"
        backLabel="← Back to admin weekly summary"
      />
      <PageHeader
        title="Admin — line detail"
        description="Full line-level data for reconciliation and troubleshooting. Values come only from the server reporting function."
      />
      {lines.length > 0 ? (
        <p
          className="mb-4 text-xs text-slate-500"
          data-testid="admin-detail-diagnostics"
        >
          {lines.length} admin line{lines.length === 1 ? '' : 's'} for week
          starting{' '}
          <span className="font-mono text-slate-700">{payWeekStart}</span>
          {weekLabel !== '—' ? ` (${weekLabel})` : null}.
        </p>
      ) : null}
      {lines.length === 0 ? (
        <EmptyState
          title="No lines for this pay week"
          description={`The admin reporting function returned no lines for week starting ${payWeekStart}. Confirm the week and scope, or check backend logs if this is unexpected.`}
          testId="admin-detail-empty"
        />
      ) : (
        <AdminPayrollLineTable rows={lines} />
      )}
    </div>
  )
}
