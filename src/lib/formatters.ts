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

/**
 * Commission rate from payroll lines: DB uses a fractional multiplier (`price_ex_gst * rate`);
 * |value| ≤ 1 is treated as a fraction (0.35 → 35%), otherwise as percentage points (35 → 35%).
 */
export function formatCommissionRatePercent(value: unknown): string {
  if (value == null || value === '') return '—'
  const raw =
    typeof value === 'string' ? value.replace(/,/g, '').trim() : value
  const n = typeof raw === 'number' ? raw : Number(raw)
  if (Number.isNaN(n)) return String(value)
  const pct = Math.abs(n) <= 1 ? n * 100 : n
  return (
    new Intl.NumberFormat(undefined, {
      maximumFractionDigits: 4,
      minimumFractionDigits: 0,
    }).format(pct) + '%'
  )
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

/**
 * Compact local-time "date + 24h time" formatter used by the saved
 * quote list and detail pages (e.g. `18 Apr 2026, 14:35`). `hourCycle:
 * 'h23'` pins HH:MM 24-hour rendering regardless of user locale so the
 * two screens stay visually consistent.
 */
const dateTimeCompactFormatter = new Intl.DateTimeFormat(undefined, {
  day: '2-digit',
  month: 'short',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  hourCycle: 'h23',
})

export function formatDateTimeCompact(iso: string | null | undefined): string {
  if (!iso) return '—'
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return String(iso)
  return dateTimeCompactFormatter.format(d)
}

export function humanizeKey(key: string): string {
  return key
    .replace(/_/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase())
}

/** Table header for payroll grid keys (shared location id/name column). */
export function tableColumnTitle(key: string): string {
  if (key === 'location_name' || key === 'location_id') return 'Location'
  if (key === 'row_count' || key === 'line_count') return 'Line count'
  if (key === 'payable_line_count') return 'Payable line count'
  if (key === 'expected_no_commission_line_count') {
    return 'Expected no commission line count'
  }
  if (key === 'zero_value_line_count') return 'Zero value line count'
  if (key === 'review_line_count') return 'Review line count'
  if (key === 'derived_staff_paid_id') return 'Derived staff paid ID'
  if (key === 'derived_staff_paid_full_name') return 'Derived staff paid full name'
  if (key === 'derived_staff_paid_remuneration_plan') return 'Remuneration plan'
  if (key === 'total_actual_commission_ex_gst') return 'Total actual commission (ex GST)'
  if (key === 'total_theoretical_commission_ex_gst') {
    return 'Total theoretical commission (ex GST)'
  }
  if (key === 'total_assistant_commission_ex_gst') {
    return 'Total assistant commission (ex GST)'
  }
  if (key === 'user_id') return 'User ID'
  if (key === 'access_role') return 'Access role'
  return humanizeKey(key)
}
