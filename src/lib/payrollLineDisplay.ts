import type { WeeklyCommissionLineRow } from '@/features/payroll/types'

/**
 * "Work performed by" for commission line tables: prefer DAX-style work
 * display, then raw work / staff work names from payroll lines.
 */
export function workPerformedByFromLine(row: WeeklyCommissionLineRow): string {
  const r = row as Record<string, unknown>
  const keys = [
    'work_display_name',
    'work_full_name',
    'staff_work_name',
    'staff_work_display_name',
    'performed_by',
    'name',
  ] as const
  for (const k of keys) {
    const v = r[k]
    if (v != null && String(v).trim() !== '') return String(v).trim()
  }
  return ''
}

/**
 * "Stylist paid" (commission payee) for line tables: prefer derived paid
 * names, then import-derived / legacy staff paid labels.
 */
export function stylistPaidFromLine(row: WeeklyCommissionLineRow): string {
  const r = row as Record<string, unknown>
  const keys = [
    'derived_staff_paid_display_name',
    'derived_staff_paid_full_name',
    'staff_paid_name_derived',
    'existing_staff_paid_name',
    'staff_paid_display_name',
  ] as const
  for (const k of keys) {
    const v = r[k]
    if (v != null && String(v).trim() !== '') return String(v).trim()
  }
  return ''
}

/**
 * Reporting bucket from `product_type_short_derived` (view/RPC may expose the
 * same value as `product_type_short` on `v_admin_payroll_lines`).
 */
export function productTypeShortLabelFromLine(row: WeeklyCommissionLineRow): string {
  const r = row as Record<string, unknown>
  const raw = r.product_type_short_derived ?? r.product_type_short
  if (raw == null || String(raw).trim() === '') return '-'
  return String(raw).trim()
}

/** Sort key: null sorts empty labels last. */
export function productTypeShortSortKeyFromLine(
  row: WeeklyCommissionLineRow,
): string | null {
  const r = row as Record<string, unknown>
  const raw = r.product_type_short_derived ?? r.product_type_short
  if (raw == null || String(raw).trim() === '') return null
  return String(raw).trim()
}

/**
 * True when the resolved "Work performed by" stylist is genuinely different
 * from the "Stylist paid" recipient — e.g. an assistant performed the service
 * but commission is being paid to the senior stylist. Used by line-preview
 * tables to highlight the work-performed cell so the assistant case is
 * obvious. Returns false when either side is blank so we don't flag missing
 * data as a mismatch.
 */
export function isWorkPerformedByDifferentFromStylistPaid(
  workPerformedBy: string | null | undefined,
  stylistPaid: string | null | undefined,
): boolean {
  const a = String(workPerformedBy ?? '').trim()
  const b = String(stylistPaid ?? '').trim()
  if (a === '' || b === '') return false
  return a.toLowerCase() !== b.toLowerCase()
}
