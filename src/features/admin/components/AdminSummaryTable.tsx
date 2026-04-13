import { Link } from 'react-router-dom'

import { TableScrollArea } from '@/components/ui/TableScrollArea'
import type { AdminPayrollSummaryRow } from '@/features/admin/types'
import { isEmptyish, formatScalarText } from '@/lib/cellValue'
import {
  formatDateLabel,
  formatNzd,
  formatShortDate,
  tableColumnTitle,
} from '@/lib/formatters'

type AdminSummaryTableProps = {
  rows: AdminPayrollSummaryRow[]
}

/** Business-facing columns; omits user_id, staff_member_id, access_role, internal derived_* ids. */
function orderedVisibleKeys(sample: AdminPayrollSummaryRow): string[] {
  const keySet = new Set(Object.keys(sample))
  const out: string[] = []
  const pushIf = (k: string) => {
    if (keySet.has(k)) out.push(k)
  }
  pushIf('pay_week_end')
  pushIf('pay_date')
  if (keySet.has('location_name')) {
    out.push('location_name')
  } else {
    pushIf('location_id')
  }
  pushIf('derived_staff_paid_display_name')
  pushIf('staff_full_name')
  pushIf('total_sales_ex_gst')
  pushIf('total_actual_commission')
  pushIf('total_assistant_commission')
  pushIf('row_count')
  pushIf('payable_line_count')
  pushIf('expected_no_commission_line_count')
  pushIf('unconfigured_paid_staff_line_count')
  pushIf('has_unconfigured_paid_staff_rows')
  return out
}

const thBase =
  'border-b border-slate-200 px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-4 sm:py-3 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700'
const tdBase =
  'whitespace-nowrap px-3 py-2.5 text-slate-700 sm:px-4 sm:py-3 min-w-[6.5rem]'

function isDateLikeKey(rowKey: string): boolean {
  if (rowKey === 'pay_week_start') return false
  if (rowKey === 'pay_week_end' || rowKey === 'pay_date') return true
  if (rowKey.includes('_date') || rowKey.endsWith('_at')) return true
  return rowKey.includes('week') && rowKey.includes('start')
}

function Cell({ rowKey, value }: { rowKey: string; value: unknown }) {
  if (isEmptyish(value)) return <span className="text-slate-400">—</span>
  if (typeof value === 'boolean') {
    return <span>{value ? 'Yes' : 'No'}</span>
  }
  if (
    rowKey === 'row_count' ||
    rowKey === 'unconfigured_paid_staff_line_count' ||
    rowKey === 'payable_line_count' ||
    rowKey === 'expected_no_commission_line_count'
  ) {
    const n = typeof value === 'number' ? value : Number(value)
    return <span className="tabular-nums">{Number.isNaN(n) ? '—' : String(n)}</span>
  }
  if (
    rowKey.includes('amount') ||
    rowKey.includes('commission') ||
    rowKey.includes('sales') ||
    rowKey.includes('total_sales') ||
    rowKey.includes('price_ex_gst')
  ) {
    if (typeof value === 'number' || typeof value === 'string') {
      return <span className="tabular-nums">{formatNzd(value)}</span>
    }
  }
  if (rowKey === 'pay_week_start') {
    return <span>{formatDateLabel(String(value))}</span>
  }
  if (isDateLikeKey(rowKey)) {
    return <span>{formatShortDate(String(value))}</span>
  }
  if (typeof value === 'object' && value !== null) {
    return (
      <span className="font-mono text-xs">{JSON.stringify(value)}</span>
    )
  }
  const text = formatScalarText(value)
  return <span>{text === '' ? '—' : text}</span>
}

function stableAdminSummaryRowKey(row: AdminPayrollSummaryRow, index: number): string {
  const week =
    row.pay_week_start != null && String(row.pay_week_start).trim() !== ''
      ? String(row.pay_week_start).trim()
      : 'noweek'
  const loc =
    row.location_id != null && String(row.location_id).trim() !== ''
      ? String(row.location_id).trim()
      : 'noloc'
  const uid =
    row.user_id != null && String(row.user_id).trim() !== ''
      ? String(row.user_id).trim()
      : 'nouid'
  return `${week}-${loc}-${uid}-${index}`
}

export function AdminSummaryTable({ rows }: AdminSummaryTableProps) {
  const keys = orderedVisibleKeys(rows[0])

  if (!rows.length) {
    return null
  }

  return (
    <TableScrollArea testId="admin-summary-table">
      <table className="min-w-[760px] w-full border-collapse text-left text-sm">
        <thead className="sticky top-0 z-20 bg-slate-50 shadow-[0_1px_0_0_rgb(226_232_240)]">
          <tr>
            <th
              scope="col"
              className={`${thBase} sticky left-0 z-30 min-w-[8.5rem] bg-slate-50`}
            >
              Week
            </th>
            <th scope="col" className={thBase}>
              Pay week start
            </th>
            {keys.map((k) => (
              <th key={k} scope="col" className={thBase}>
                {tableColumnTitle(k)}
              </th>
            ))}
            <th scope="col" className={`${thBase} min-w-[5.5rem]`}>
              Detail
            </th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row, idx) => {
            const weekRaw = row.pay_week_start
            const weekStart =
              weekRaw != null && String(weekRaw).trim() !== ''
                ? String(weekRaw).trim()
                : ''
            const rowKey = stableAdminSummaryRowKey(row, idx)
            return (
              <tr
                key={rowKey}
                className="group border-b border-slate-100 odd:bg-white even:bg-slate-50/90 hover:bg-violet-50/60"
              >
                <td
                  className={`${tdBase} sticky left-0 z-10 min-w-[8.5rem] border-slate-100 font-medium ${
                    idx % 2 === 0 ? 'bg-white' : 'bg-slate-50/90'
                  } group-hover:bg-violet-50/60`}
                >
                  {weekStart ? (
                    <Cell rowKey="pay_week_start" value={row.pay_week_start} />
                  ) : (
                    <span className="text-slate-400">—</span>
                  )}
                </td>
                <td className={tdBase}>
                  {weekStart ? (
                    <span>{formatShortDate(row.pay_week_start)}</span>
                  ) : (
                    <span className="text-slate-400">—</span>
                  )}
                </td>
                {keys.map((k) => (
                  <td key={k} className={tdBase}>
                    <Cell rowKey={k} value={row[k]} />
                  </td>
                ))}
                <td className={`${tdBase} min-w-[5.5rem]`}>
                  {weekStart ? (
                    <Link
                      to={`/app/admin/payroll/${encodeURIComponent(weekStart)}`}
                      className="font-medium text-violet-700 hover:text-violet-900"
                    >
                      View lines
                    </Link>
                  ) : (
                    <span className="text-slate-400">—</span>
                  )}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </TableScrollArea>
  )
}
