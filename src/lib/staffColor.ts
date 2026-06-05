/**
 * Deterministic colour for a staff member id, stable across renders and
 * sessions. Used by the all-staff stacked chart on Staff Trends and the
 * Assistant Comm. contributor icons on My Sales so the same assistant
 * gets the same swatch wherever they appear.
 *
 * The palette mirrors the one historically used in StaffTrendsPage; we
 * keep it here as well so My Sales does not need to depend on the
 * Staff Trends page module.
 */
export const STAFF_COLOR_PALETTE = [
  '#7c3aed', '#0ea5e9', '#16a34a', '#f59e0b', '#ef4444',
  '#0891b2', '#db2777', '#65a30d', '#9333ea', '#0d9488',
  '#ea580c', '#475569', '#a855f7', '#06b6d4', '#84cc16',
  '#fb923c',
] as const

const FALLBACK_COLOR = '#475569'

/** djb2-style hash → palette slot. Empty / missing id falls back to slate. */
export function colorForStaffId(id: string | null | undefined): string {
  const s = String(id ?? '').trim()
  if (s === '') return FALLBACK_COLOR
  let h = 0
  for (let i = 0; i < s.length; i++) {
    h = ((h << 5) - h + s.charCodeAt(i)) | 0
  }
  return STAFF_COLOR_PALETTE[Math.abs(h) % STAFF_COLOR_PALETTE.length]
}
