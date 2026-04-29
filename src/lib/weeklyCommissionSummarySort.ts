import type { WeeklyCommissionSummaryRow } from '@/features/payroll/types'

import {
  compareScalarsForSort,
  type ColumnSortState,
  stableSorted,
} from '@/lib/tableSort'

export const STYLIST_SUMMARY_SORT_PAY_WEEK_START = '__pay_week_start__'

function stylistSummarySortKind(rowKey: string): 'date' | 'number' | 'text' {
  if (
    rowKey === STYLIST_SUMMARY_SORT_PAY_WEEK_START ||
    rowKey === 'pay_week_start' ||
    rowKey === 'pay_week_end' ||
    rowKey === 'pay_date'
  ) {
    return 'date'
  }
  if (
    rowKey === 'line_count' ||
    rowKey === 'row_count' ||
    rowKey === 'payable_line_count' ||
    rowKey === 'expected_no_commission_line_count' ||
    rowKey === 'zero_value_line_count' ||
    rowKey === 'review_line_count' ||
    rowKey === 'unconfigured_paid_staff_line_count' ||
    rowKey === 'total_sales_ex_gst' ||
    rowKey === 'total_actual_commission_ex_gst' ||
    rowKey === 'total_theoretical_commission_ex_gst' ||
    rowKey === 'total_assistant_commission_ex_gst' ||
    rowKey === 'total_actual_commission' ||
    rowKey === 'total_assistant_commission'
  ) {
    return 'number'
  }
  return 'text'
}

function getStylistSummarySortValue(
  row: WeeklyCommissionSummaryRow,
  sortKey: string,
): unknown {
  if (sortKey === STYLIST_SUMMARY_SORT_PAY_WEEK_START) {
    return row.pay_week_start ?? null
  }
  return row[sortKey as keyof WeeklyCommissionSummaryRow]
}

export function sortStylistCommissionSummaryRows(
  rows: WeeklyCommissionSummaryRow[],
  sort: ColumnSortState,
): WeeklyCommissionSummaryRow[] {
  if (sort == null) return rows
  const kind = stylistSummarySortKind(sort.key)
  return stableSorted(rows, (a, b) =>
    compareScalarsForSort(
      getStylistSummarySortValue(a, sort.key),
      getStylistSummarySortValue(b, sort.key),
      kind,
      sort.dir,
    ),
  )
}
