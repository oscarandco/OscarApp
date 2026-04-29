import type { AdminPayrollSummaryRow } from '@/features/admin/types'

/**
 * Work performed (summary): use RPC `work_performed_by` when present; otherwise
 * `staff_full_name` from the admin summary row (no extra SQL required).
 */
export function workPerformedByFromAdminSummaryRow(
  row: AdminPayrollSummaryRow,
): string {
  const w = row.work_performed_by
  if (w != null && String(w).trim() !== '') return String(w).trim()
  const s = row.staff_full_name
  if (s != null && String(s).trim() !== '') return String(s).trim()
  return ''
}

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
  if (rowKey === '__admin_summary_work_performed') {
    const t = workPerformedByFromAdminSummaryRow(row)
    return t === '' ? null : t
  }
  return row[rowKey as keyof AdminPayrollSummaryRow]
}
