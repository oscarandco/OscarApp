import type { WeeklyCommissionLineRow } from '@/features/payroll/types'

import { stylistPaidFromLine, workPerformedByFromLine } from '@/lib/payrollLineDisplay'
import {
  compareScalarsForSort,
  type ColumnSortState,
  stableSorted,
} from '@/lib/tableSort'

function lineSortKind(rowKey: string): 'date' | 'number' | 'text' {
  if (
    rowKey === 'sale_date' ||
    rowKey === 'sale_datetime' ||
    rowKey === 'pay_week_start' ||
    rowKey === 'pay_week_end' ||
    rowKey === 'pay_date'
  ) {
    return 'date'
  }
  if (
    rowKey === 'quantity' ||
    rowKey === 'price_ex_gst' ||
    rowKey === 'price_incl_gst' ||
    rowKey === 'actual_commission_rate' ||
    rowKey.includes('amount') ||
    rowKey.includes('commission') ||
    rowKey.includes('amt_ex_gst')
  ) {
    return 'number'
  }
  return 'text'
}

export function getPayrollLineSortValue(
  row: WeeklyCommissionLineRow,
  rowKey: string,
): unknown {
  if (rowKey === '__work_performed_by') {
    const t = workPerformedByFromLine(row)
    return t === '' ? null : t
  }
  if (rowKey === '__stylist_paid') {
    const t = stylistPaidFromLine(row)
    return t === '' ? null : t
  }
  return row[rowKey as keyof WeeklyCommissionLineRow]
}

export function sortPayrollLineRows(
  rows: WeeklyCommissionLineRow[],
  sort: ColumnSortState,
): WeeklyCommissionLineRow[] {
  if (sort == null) return rows
  const kind = lineSortKind(sort.key)
  return stableSorted(rows, (a, b) =>
    compareScalarsForSort(
      getPayrollLineSortValue(a, sort.key),
      getPayrollLineSortValue(b, sort.key),
      kind,
      sort.dir,
    ),
  )
}

/** Preview modal fixed columns — same value extraction as modal cells. */
export type CommissionLinePreviewSortKey =
  | 'invoice'
  | 'sale_date'
  | 'customer_name'
  | 'product_service_name'
  | 'work_performed_by'
  | 'stylist_paid'
  | 'price_ex_gst'
  | 'price_incl_gst'
  | 'actual_commission_rate'
  | 'actual_commission'

function previewSortKind(key: CommissionLinePreviewSortKey): 'date' | 'number' | 'text' {
  if (key === 'sale_date') return 'date'
  if (
    key === 'price_ex_gst' ||
    key === 'price_incl_gst' ||
    key === 'actual_commission_rate' ||
    key === 'actual_commission'
  ) {
    return 'number'
  }
  return 'text'
}

function getPreviewLineSortValue(
  row: WeeklyCommissionLineRow,
  key: CommissionLinePreviewSortKey,
): unknown {
  const raw = row as Record<string, unknown>
  if (key === 'work_performed_by') {
    const t = workPerformedByFromLine(row)
    return t === '' ? null : t
  }
  if (key === 'stylist_paid') {
    const t = stylistPaidFromLine(row)
    return t === '' ? null : t
  }
  if (key === 'actual_commission') {
    return raw.actual_commission_amt_ex_gst ?? raw.actual_commission_amount ?? null
  }
  return row[key as keyof WeeklyCommissionLineRow]
}

export function sortCommissionLinePreviewRows(
  rows: WeeklyCommissionLineRow[],
  sort: ColumnSortState,
): WeeklyCommissionLineRow[] {
  if (sort == null) return rows
  const key = sort.key as CommissionLinePreviewSortKey
  const kind = previewSortKind(key)
  return stableSorted(rows, (a, b) =>
    compareScalarsForSort(
      getPreviewLineSortValue(a, key),
      getPreviewLineSortValue(b, key),
      kind,
      sort.dir,
    ),
  )
}
