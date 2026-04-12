/** Compare pay week start dates (newest first). */
export function comparePayWeekStartDesc(
  a: string | null | undefined,
  b: string | null | undefined,
): number {
  const ta = parsePayWeekTime(a)
  const tb = parsePayWeekTime(b)
  return tb - ta
}

function parsePayWeekTime(v: string | null | undefined): number {
  if (v == null || v === '') return Number.NEGATIVE_INFINITY
  const t = Date.parse(v.includes('T') ? v : `${v}T12:00:00`)
  return Number.isNaN(t) ? Number.NEGATIVE_INFINITY : t
}

/**
 * Sort weekly summary rows: newest `pay_week_start` first, then stable location order
 * so location splits for the same week stay visible and ordered.
 */
export function sortSummaryRowsNewestFirst<
  T extends {
    pay_week_start?: string | null
    location_id?: string | null
  },
>(rows: T[]): T[] {
  return [...rows].sort((r1, r2) => {
    const c = comparePayWeekStartDesc(r1.pay_week_start, r2.pay_week_start)
    if (c !== 0) return c
    const l1 =
      r1.location_id != null && r1.location_id !== ''
        ? String(r1.location_id)
        : ''
    const l2 =
      r2.location_id != null && r2.location_id !== ''
        ? String(r2.location_id)
        : ''
    return l1.localeCompare(l2, undefined, { numeric: true })
  })
}
