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
