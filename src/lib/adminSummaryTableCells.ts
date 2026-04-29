import type { AdminPayrollSummaryRow } from '@/features/admin/types'

/** Stylist paid (summary): display name, then full name. */
export function stylistPaidFromAdminSummaryRow(row: AdminPayrollSummaryRow): string {
  const d = row.derived_staff_paid_display_name
  const f = row.derived_staff_paid_full_name
  if (d != null && String(d).trim() !== '') return String(d).trim()
  if (f != null && String(f).trim() !== '') return String(f).trim()
  return ''
}

export function adminSummaryCellValue(
  row: AdminPayrollSummaryRow,
  rowKey: string,
): unknown {
  if (rowKey === '__admin_summary_stylist_paid') {
    const t = stylistPaidFromAdminSummaryRow(row)
    return t === '' ? null : t
  }
  return row[rowKey as keyof AdminPayrollSummaryRow]
}
