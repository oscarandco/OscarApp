import type { AdminPayrollLineRow } from '@/features/admin/types'
import { PayrollLineTable } from '@/features/payroll/components/PayrollLineTable'

type AdminPayrollLineTableProps = {
  rows: AdminPayrollLineRow[]
}

/** Admin line grid; same presentation as stylist lines, scoped for admin RPC rows. */
export function AdminPayrollLineTable({ rows }: AdminPayrollLineTableProps) {
  return (
    <div data-testid="admin-payroll-line-table">
      <PayrollLineTable rows={rows} />
    </div>
  )
}
