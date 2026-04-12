import { useMemo } from 'react'
import { useParams } from 'react-router-dom'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { PayrollLineTable } from '@/features/payroll/components/PayrollLineTable'
import { PayrollWeekHeader } from '@/features/payroll/components/PayrollWeekHeader'
import { useMyWeeklyCommissionLines } from '@/features/payroll/hooks/useMyWeeklyCommissionLines'
import { formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'
import { parsePayWeekRouteParam } from '@/lib/routeParams'

export function PayrollWeekDetailPage() {
  const { payWeekStart: rawParam } = useParams<{ payWeekStart: string }>()
  const parsed = parsePayWeekRouteParam(rawParam)
  const payWeekForQuery = parsed.kind === 'ok' ? parsed.value : undefined

  const { data, isLoading, isError, error, refetch } =
    useMyWeeklyCommissionLines(payWeekForQuery)

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
      <div data-testid="payroll-detail-page">
        <ErrorState
          title="No pay week selected"
          message="Open this page from the weekly summary by choosing a pay week (View lines)."
          testId="payroll-detail-param-error"
        />
      </div>
    )
  }

  if (parsed.kind === 'invalid') {
    return (
      <div data-testid="payroll-detail-page">
        <ErrorState
          title="Invalid pay week link"
          message={`${parsed.reason} (Received: ${parsed.rawDisplay})`}
          testId="payroll-detail-param-error"
        />
      </div>
    )
  }

  const payWeekStart = parsed.value

  if (isLoading) {
    return (
      <div data-testid="payroll-detail-page">
        <PayrollWeekHeader payWeekStart={payWeekStart} />
        <LoadingState
          message="Loading commission lines…"
          testId="payroll-detail-loading"
        />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="payroll-detail-page">
        <PayrollWeekHeader payWeekStart={payWeekStart} />
        <ErrorState
          title="Could not load lines for this week"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="payroll-detail-error"
        />
      </div>
    )
  }

  const lines = data ?? []
  const weekLabel = formatShortDate(payWeekStart)

  return (
    <div data-testid="payroll-detail-page" className="max-w-[100vw]">
      <PayrollWeekHeader
        payWeekStart={payWeekStart}
        payWeekEnd={context.payWeekEnd}
        payDate={context.payDate}
      />
      <PageHeader
        title="Line detail"
        description="All commission lines returned for this pay week. Use this view to audit amounts and statuses."
      />
      {lines.length > 0 ? (
        <p
          className="mb-4 text-xs text-slate-500"
          data-testid="payroll-detail-diagnostics"
        >
          {lines.length} line{lines.length === 1 ? '' : 's'} for week starting{' '}
          <span className="font-mono text-slate-700">{payWeekStart}</span>
          {weekLabel !== '—' ? ` (${weekLabel})` : null}.
        </p>
      ) : null}
      {lines.length === 0 ? (
        <EmptyState
          title="No lines for this pay week"
          description={`The reporting service returned no line items for week starting ${payWeekStart}. If sales should appear here, confirm the week is posted or contact your manager.`}
          testId="payroll-detail-empty"
        />
      ) : (
        <PayrollLineTable rows={lines} />
      )}
    </div>
  )
}
