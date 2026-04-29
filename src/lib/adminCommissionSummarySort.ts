import type { AdminPayrollSummaryRow } from '@/features/admin/types'

import { adminSummaryCellValue } from '@/lib/adminSummaryTableCells'
import {
  compareScalarsForSort,
  type ColumnSortState,
  stableSorted,
} from '@/lib/tableSort'

export const ADMIN_SUMMARY_SORT_PAY_WEEK_START = '__pay_week_start__'

function adminSummarySortKind(rowKey: string): 'date' | 'number' | 'text' {
  if (
    rowKey === ADMIN_SUMMARY_SORT_PAY_WEEK_START ||
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

function getAdminSummarySortValue(
  row: AdminPayrollSummaryRow,
  sortKey: string,
): unknown {
  if (sortKey === ADMIN_SUMMARY_SORT_PAY_WEEK_START) {
    return row.pay_week_start ?? null
  }
  return adminSummaryCellValue(row, sortKey)
}

export function sortAdminCommissionSummaryRows(
  rows: AdminPayrollSummaryRow[],
  sort: ColumnSortState,
): AdminPayrollSummaryRow[] {
  if (sort == null) return rows
  const kind = adminSummarySortKind(sort.key)
  return stableSorted(rows, (a, b) =>
    compareScalarsForSort(
      getAdminSummarySortValue(a, sort.key),
      getAdminSummarySortValue(b, sort.key),
      kind,
      sort.dir,
    ),
  )
}
