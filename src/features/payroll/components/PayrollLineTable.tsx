import { TableScrollArea } from '@/components/ui/TableScrollArea'
import type { WeeklyCommissionLineRow } from '@/features/payroll/types'
import { isEmptyish, formatScalarText } from '@/lib/cellValue'
import { formatNzd, formatShortDate, tableColumnTitle } from '@/lib/formatters'

type PayrollLineTableProps = {
  rows: WeeklyCommissionLineRow[]
}

const PREFERRED_KEYS = [
  'sale_date',
  'pay_week_start',
  'pay_week_end',
  'pay_date',
  'invoice',
  'customer_name',
  'product_service_name',
  'quantity',
  'price_ex_gst',
  'derived_staff_paid_display_name',
  'actual_commission_amount',
  'assistant_commission_amount',
  'payroll_status',
  'stylist_visible_note',
  'location_name',
  'location_id',
  'access_role',
  'user_id',
  'id',
] as const

const thBase =
  'border-b border-slate-200 px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-4 sm:py-3 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700'
const tdBase = 'px-3 py-2.5 text-slate-700 sm:px-4 sm:py-3 min-w-[5.5rem]'

function columnKeys(row: WeeklyCommissionLineRow | undefined): string[] {
  if (!row) return []
  const keys = Object.keys(row)
  const preferred = PREFERRED_KEYS as readonly string[]
  const head = preferred.filter((k) => keys.includes(k))
  const rest = keys
    .filter((k) => !head.includes(k))
    .sort((a, b) => a.localeCompare(b))
  let merged = [...head, ...rest]
  if (merged.includes('location_name') && merged.includes('location_id')) {
    merged = merged.filter((k) => k !== 'location_id')
  }
  return merged
}

function isDateLikeKey(rowKey: string): boolean {
  if (
    rowKey === 'sale_date' ||
    rowKey === 'pay_date' ||
    rowKey === 'pay_week_end'
  ) {
    return true
  }
  if (rowKey.includes('_date') || rowKey.endsWith('_at')) return true
  return rowKey.includes('week') && rowKey.includes('start')
}

function stableLineRowKey(row: WeeklyCommissionLineRow, index: number): string {
  const id = row.id
  if (id != null && String(id).trim() !== '') {
    return `id:${String(id).trim()}`
  }
  const inv = row.invoice
  if (inv != null && String(inv).trim() !== '') {
    const sd =
      row.sale_date != null && String(row.sale_date).trim() !== ''
        ? String(row.sale_date).trim()
        : 'nodate'
    return `inv:${String(inv).trim()}-${sd}-${index}`
  }
  const pw =
    row.pay_week_start != null && String(row.pay_week_start).trim() !== ''
      ? String(row.pay_week_start).trim()
      : 'nopw'
  return `line:${pw}-${index}`
}

function Cell({ rowKey, value }: { rowKey: string; value: unknown }) {
  if (isEmptyish(value)) return <span className="text-slate-400">—</span>
  if (typeof value === 'boolean') {
    return <span>{value ? 'Yes' : 'No'}</span>
  }
  if (rowKey === 'quantity') {
    const n = typeof value === 'number' ? value : Number(value)
    return (
      <span className="tabular-nums">
        {Number.isNaN(n) ? '—' : n.toLocaleString()}
      </span>
    )
  }
  if (
    rowKey.includes('amount') ||
    rowKey.includes('commission') ||
    rowKey.includes('price_ex_gst') ||
    rowKey.includes('sales')
  ) {
    return <span className="tabular-nums">{formatNzd(value)}</span>
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

export function PayrollLineTable({ rows }: PayrollLineTableProps) {
  const keys = columnKeys(rows[0])

  if (!rows.length) {
    return null
  }

  return (
    <TableScrollArea testId="payroll-line-table">
      <table className="min-w-[880px] w-full border-collapse text-left text-sm">
        <thead className="sticky top-0 z-20 bg-slate-50 shadow-[0_1px_0_0_rgb(226_232_240)]">
          <tr>
            {keys.map((k) => (
              <th key={k} scope="col" className={`${thBase} min-w-[6rem]`}>
                {tableColumnTitle(k)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, idx) => (
            <tr
              key={stableLineRowKey(row, idx)}
              className="border-b border-slate-100 odd:bg-white even:bg-slate-50/90 hover:bg-violet-50/60"
            >
              {keys.map((k) => (
                <td key={k} className={tdBase}>
                  <Cell rowKey={k} value={row[k]} />
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </TableScrollArea>
  )
}
