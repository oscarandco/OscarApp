import { useMemo } from 'react'

import type { SalesDailySheetsDataSourceRow } from '@/features/payroll/types'
import { formatShortDate } from '@/lib/formatters'

type WeeklySummaryDataSourceLinesProps = {
  sources: SalesDailySheetsDataSourceRow[] | undefined
  /** e.g. `payroll-summary-data-sources` or `admin-summary-data-sources` */
  listTestId: string
  /** Prefix for each line's `data-testid`, e.g. `payroll-summary-data-source` */
  lineTestIdPrefix: string
  /**
   * When `toolbar`, the list has no bottom margin (sits in the table
   * toolbar row). Default `standalone` keeps legacy spacing.
   */
  variant?: 'standalone' | 'toolbar'
}

function locationSortKey(name: string): number {
  const n = name.toLowerCase()
  if (n.includes('orewa')) return 0
  if (n.includes('takapuna')) return 1
  return 2
}

function titleCaseLocationLabel(name: string): string {
  const parts = name.trim().split(/\s+/).filter(Boolean)
  if (parts.length === 0) return name
  return parts
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase())
    .join(' ')
}

function displayLocationName(src: SalesDailySheetsDataSourceRow): string {
  const raw =
    (src.location_name && String(src.location_name).trim()) ||
    (src.location_code && String(src.location_code).trim()) ||
    'Unknown location'
  return titleCaseLocationLabel(raw)
}

export function WeeklySummaryDataSourceLines({
  sources,
  listTestId,
  lineTestIdPrefix,
  variant = 'standalone',
}: WeeklySummaryDataSourceLinesProps) {
  const sorted = useMemo(() => {
    const list = [...(sources ?? [])]
    list.sort((a, b) => {
      const la = displayLocationName(a).toLowerCase()
      const lb = displayLocationName(b).toLowerCase()
      const ra = locationSortKey(la)
      const rb = locationSortKey(lb)
      if (ra !== rb) return ra - rb
      return la.localeCompare(lb, undefined, { sensitivity: 'base' })
    })
    return list
  }, [sources])

  if (sorted.length === 0) return null

  const listMb = variant === 'toolbar' ? '' : 'mb-4'

  return (
    <ul
      className={`min-w-0 flex-1 space-y-1 text-xs leading-snug text-slate-600 ${listMb}`}
      data-testid={listTestId}
    >
      {sorted.map((src, idx) => {
        const loc = displayLocationName(src)
        const rowCount = src.row_count == null ? 0 : Number(src.row_count)
        const first = formatShortDate(src.first_sale_date ?? null)
        const last = formatShortDate(src.last_sale_date ?? null)
        return (
          <li
            key={src.batch_id ?? `${loc}-${idx}`}
            data-testid={`${lineTestIdPrefix}-${idx + 1}`}
          >
            <span className="font-medium text-slate-700">
              Data source {idx + 1} - {loc}:
            </span>{' '}
            {Number.isFinite(rowCount) ? rowCount.toLocaleString() : '0'} rows (
            {first} - {last})
          </li>
        )
      })}
    </ul>
  )
}
