const nzdFormatter = new Intl.NumberFormat(undefined, {
  style: 'currency',
  currency: 'NZD',
  maximumFractionDigits: 2,
})

/** Format a number or numeric string as NZD (salon payroll default). */
export function formatNzd(value: unknown): string {
  if (value == null || value === '') return '—'
  const n = typeof value === 'number' ? value : Number(value)
  if (Number.isNaN(n)) return String(value)
  return nzdFormatter.format(n)
}

/** Display a date-only ISO string or timestamp in the user locale. */
export function formatDateLabel(isoDate: string | null | undefined): string {
  if (!isoDate) return '—'
  const d = new Date(isoDate + (isoDate.includes('T') ? '' : 'T12:00:00'))
  if (Number.isNaN(d.getTime())) return String(isoDate)
  return d.toLocaleDateString(undefined, {
    weekday: 'short',
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  })
}

/** Short date without weekday (e.g. tables). */
export function formatShortDate(isoDate: string | null | undefined): string {
  if (!isoDate) return '—'
  const d = new Date(isoDate + (isoDate.includes('T') ? '' : 'T12:00:00'))
  if (Number.isNaN(d.getTime())) return String(isoDate)
  return d.toLocaleDateString(undefined, {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  })
}

/**
 * Compact pay-week label for badges and chips (same as short date; centralized for UI tweaks).
 */
export function formatWeekBadgeLabel(isoDate: string | null | undefined): string {
  return formatShortDate(isoDate)
}

export function humanizeKey(key: string): string {
  return key
    .replace(/_/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase())
}

/** Table header for payroll grid keys (shared location id/name column). */
export function tableColumnTitle(key: string): string {
  if (key === 'location_name' || key === 'location_id') return 'Location'
  if (key === 'row_count') return 'Line count'
  if (key === 'payable_line_count') return 'Payable line count'
  if (key === 'expected_no_commission_line_count') {
    return 'Expected no commission line count'
  }
  return humanizeKey(key)
}
