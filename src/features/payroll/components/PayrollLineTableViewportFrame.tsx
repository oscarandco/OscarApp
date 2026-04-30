import { PayrollLineTable } from '@/features/payroll/components/PayrollLineTable'
import type { WeeklyCommissionLineRow } from '@/features/payroll/types'

/**
 * Full-week line detail: fills remaining main-column space; table scrolls inside
 * (`fillViewport` + compact). Used by admin and stylist week detail routes.
 */
export function PayrollLineTableViewportFrame({
  rows,
  className = '',
}: {
  rows: WeeklyCommissionLineRow[]
  className?: string
}) {
  return (
    <div
      className={`flex min-h-0 min-w-0 flex-1 flex-col${className ? ` ${className}` : ''}`}
      data-testid="payroll-line-table-viewport"
    >
      <PayrollLineTable
        rows={rows}
        scrollFrame="fillViewport"
        density="compact"
      />
    </div>
  )
}
