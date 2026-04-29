import type { TableARow, TableBRow } from '@/features/admin/utils/weeklyCommissionDashboardAggregates'

import {
  compareScalarsForSort,
  type ColumnSortState,
  stableSorted,
} from '@/lib/tableSort'

export type WeeklyDashboardTableAKey =
  | 'staffPaid'
  | 'profProd'
  | 'retailProd'
  | 'services'
  | 'total'

export type WeeklyDashboardTableBKey =
  | 'staffPaid'
  | 'commProducts'
  | 'commServices'
  | 'total'

function kindForTableA(k: string): 'text' | 'number' {
  return k === 'staffPaid' ? 'text' : 'number'
}

export function sortWeeklyDashboardTableARows(
  rows: TableARow[],
  sort: ColumnSortState,
): TableARow[] {
  if (sort == null) return rows
  const key = sort.key as WeeklyDashboardTableAKey
  const kind = kindForTableA(key)
  return stableSorted(rows, (a, b) =>
    compareScalarsForSort(a[key], b[key], kind, sort.dir),
  )
}

export function sortWeeklyDashboardTableBRows(
  rows: TableBRow[],
  sort: ColumnSortState,
): TableBRow[] {
  if (sort == null) return rows
  const key = sort.key as WeeklyDashboardTableBKey
  const kind = key === 'staffPaid' ? 'text' : 'number'
  return stableSorted(rows, (a, b) =>
    compareScalarsForSort(a[key], b[key], kind, sort.dir),
  )
}
