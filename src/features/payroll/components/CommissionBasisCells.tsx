import type { WeeklyCommissionLineRow } from '@/features/payroll/types'
import { formatNzd } from '@/lib/formatters'

const basisColumns = [
  ['actual_product_cost_ex_gst', 'Product cost ex GST'],
  ['actual_commissionable_ex_gst', 'Commissionable ex GST'],
  ['theoretical_product_cost_ex_gst', 'Theoretical product cost ex GST'],
  ['theoretical_commissionable_ex_gst', 'Theoretical commissionable ex GST'],
] as const

export function CommissionBasisHeaderCells({ className }: { className: string }) {
  return <>{basisColumns.map(([field, label]) => <th key={field} scope="col" className={`${className} min-w-24 text-right`} title={label}>{label}</th>)}</>
}

export function CommissionBasisCells({ row, className }: { row: WeeklyCommissionLineRow; className: string }) {
  const credit = row.price_ex_gst != null && Number(row.price_ex_gst) < 0
  return <>{basisColumns.map(([field], index) => <td key={field} className={`${className} whitespace-nowrap text-right tabular-nums`}>
    {row[field] != null ? formatNzd(row[field]) : '—'}
    {credit && index === 0 ? <small className="mt-1 block max-w-52 whitespace-normal text-left text-[10px] text-amber-900">Credit uses credit-date rules; check the original sale for cross-period or partial refunds.</small> : null}
  </td>)}</>
}
