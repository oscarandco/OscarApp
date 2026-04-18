/**
 * Shared grid template for every Guest Quote worksheet row. One template
 * keeps the controls column perfectly aligned across all sections, so
 * the control start-x is identical on every row on the page.
 *
 *   col 1 — leading actions      (mobile: 18px, sm+: 20px, admin: 40/44px)
 *   col 2 — green price          (mobile: 48px, sm+: 56px)
 *   col 3 — service label        (mobile: 140px, sm+: 240px)
 *   col 4 — control group        (remaining width)
 *
 * Admin users see a second per-row button (a red "E") alongside the
 * clear "x", so col 1 widens to fit both circles + a gap.
 *
 * Gap tightened to 2px on mobile (from 4px) and 6px on sm+ to free up
 * as much horizontal room as possible for controls on phone widths;
 * the tighter mobile gap also noticeably pulls the service label in
 * toward the green price column, which otherwise felt a touch far.
 *
 * Every row on the page uses the same template string, so column
 * starts stay identical within each breakpoint — alignment holds.
 */
const ROW_GRID_CLASSES_DEFAULT =
  'grid grid-cols-[18px_48px_140px_minmax(0,1fr)] gap-x-0.5 sm:grid-cols-[20px_56px_240px_minmax(0,1fr)] sm:gap-x-1.5 items-center py-1 text-[13px]'
const ROW_GRID_CLASSES_ADMIN =
  'grid grid-cols-[40px_48px_140px_minmax(0,1fr)] gap-x-0.5 sm:grid-cols-[44px_56px_240px_minmax(0,1fr)] sm:gap-x-1.5 items-center py-1 text-[13px]'

/**
 * Returns the grid-template string for a Guest Quote worksheet row.
 * Shared between the service field component and the Green Fee row on
 * the Guest Quote page so both stay column-aligned when an elevated
 * user is viewing the page.
 */
export function guestQuoteRowGridClasses(adminEditMode: boolean): string {
  return adminEditMode ? ROW_GRID_CLASSES_ADMIN : ROW_GRID_CLASSES_DEFAULT
}
