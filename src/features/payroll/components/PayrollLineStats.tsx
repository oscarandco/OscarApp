import type { WeeklyCommissionLineRow } from '@/features/payroll/types'
import { formatNzd } from '@/lib/formatters'

type PayrollLineStatsProps = {
  /** Rows currently shown in the table (after client-side filters). */
  rows: WeeklyCommissionLineRow[]
}

function sumActualCommission(rows: WeeklyCommissionLineRow[]): number | null {
  let total = 0
  let found = false
  for (const r of rows) {
    const raw = r as Record<string, unknown>
    const v =
      raw.actual_commission_amt_ex_gst ?? raw.actual_commission_amount ?? null
    if (v != null && v !== '') {
      const n = typeof v === 'number' ? v : Number(v)
      if (!Number.isNaN(n)) {
        total += n
        found = true
      }
    }
  }
  return found ? total : null
}

function sumSalesExGst(rows: WeeklyCommissionLineRow[]): number | null {
  let total = 0
  let found = false
  for (const r of rows) {
    const v = r.price_ex_gst
    if (v != null && v !== '') {
      const n = typeof v === 'number' ? v : Number(v)
      if (!Number.isNaN(n)) {
        total += n
        found = true
      }
    }
  }
  return found ? total : null
}

export function PayrollLineStats({ rows }: PayrollLineStatsProps) {
  const commission = sumActualCommission(rows)
  const sales = sumSalesExGst(rows)

  return (
    <div className="space-y-3" data-testid="payroll-line-stats">
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        <div className="rounded-lg border border-slate-200 bg-white px-4 py-3 shadow-sm">
          <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
            Total actual commission
          </p>
          <p className="mt-1 text-2xl font-semibold tabular-nums text-slate-900">
            {commission != null ? formatNzd(commission) : '—'}
          </p>
        </div>
        <div className="rounded-lg border border-slate-200 bg-white px-4 py-3 shadow-sm">
          <p className="text-xs font-medium uppercase tracking-wide text-slate-500">
            Total sales
          </p>
          <p className="mt-1 text-2xl font-semibold tabular-nums text-slate-900">
            {sales != null ? formatNzd(sales) : '—'}
          </p>
        </div>
      </div>
    </div>
  )
}
