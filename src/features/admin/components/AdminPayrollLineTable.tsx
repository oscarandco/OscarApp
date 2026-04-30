import type { AdminPayrollLineRow } from '@/features/admin/types'
import { PayrollLineTableViewportFrame } from '@/features/payroll/components/PayrollLineTableViewportFrame'

type AdminPayrollLineTableProps = {
  rows: AdminPayrollLineRow[]
}

/** Admin line grid; viewport-filling scroll frame + compact density on the week detail route. */
export function AdminPayrollLineTable({ rows }: AdminPayrollLineTableProps) {
  return (
    <div
      className="flex min-h-0 min-w-0 flex-1 flex-col"
      data-testid="admin-payroll-line-table"
    >
      <PayrollLineTableViewportFrame rows={rows} />
    </div>
  )
}
