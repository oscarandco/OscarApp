import type { SalesDailySheetsDataSourceRow } from '@/features/payroll/types'
import { formatDateLabel } from '@/lib/formatters'

type WeeklySummaryDataSourceLinesProps = {
  sources: SalesDailySheetsDataSourceRow[] | undefined
  /** e.g. `payroll-summary-data-sources` or `admin-summary-data-sources` */
  listTestId: string
  /** Prefix for each line's `data-testid`, e.g. `payroll-summary-data-source` */
  lineTestIdPrefix: string
}

export function WeeklySummaryDataSourceLines({
  sources,
  listTestId,
  lineTestIdPrefix,
}: WeeklySummaryDataSourceLinesProps) {
  const list = sources ?? []
  if (list.length === 0) return null

  return (
    <ul
      className="mb-4 space-y-1 text-xs text-slate-600"
      data-testid={listTestId}
    >
      {list.map((src, idx) => {
        const name =
          (src.source_file_name && String(src.source_file_name).trim()) ||
          'Unknown source file'
        const rowCount = src.row_count == null ? 0 : Number(src.row_count)
        const first = formatDateLabel(src.first_sale_date ?? null)
        const last = formatDateLabel(src.last_sale_date ?? null)
        return (
          <li
            key={src.batch_id ?? `${name}-${idx}`}
            data-testid={`${lineTestIdPrefix}-${idx + 1}`}
          >
            <span className="font-medium text-slate-700">
              Data source {idx + 1}:
            </span>{' '}
            {name} —{' '}
            {Number.isFinite(rowCount) ? rowCount.toLocaleString() : '0'} rows,
            first row {first}, last row {last}
          </li>
        )
      })}
    </ul>
  )
}
