/**
 * Shared grid template for every Guest Quote worksheet row. One template
 * keeps the controls column perfectly aligned across all sections, so
 * the control start-x is identical on every row on the page.
 *
 *   col 1 — leading actions      (20px normal / 44px for admin edit mode)
 *   col 2 — green price          (56px, fits "$1,000.00")
 *   col 3 — service label        (240px, fits longest live label)
 *   col 4 — control group        (remaining width)
 *
 * Admin users see a second per-row button (a red "E") alongside the
 * clear "x", so col 1 widens to fit both circles + a gap. Non-admin
 * users get the original 20px column and the layout is unchanged.
 *
 * Gap tightened to 6px to remove the wide dead-space between price,
 * label, and controls that earlier iterations suffered from.
 */
const ROW_GRID_CLASSES_DEFAULT =
  'grid grid-cols-[20px_56px_240px_minmax(0,1fr)] items-center gap-x-1.5 py-1 text-[13px]'
const ROW_GRID_CLASSES_ADMIN =
  'grid grid-cols-[44px_56px_240px_minmax(0,1fr)] items-center gap-x-1.5 py-1 text-[13px]'

/**
 * Returns the grid-template string for a Guest Quote worksheet row.
 * Shared between the service field component and the Green Fee row on
 * the Guest Quote page so both stay column-aligned when an elevated
 * user is viewing the page.
 */
export function guestQuoteRowGridClasses(adminEditMode: boolean): string {
  return adminEditMode ? ROW_GRID_CLASSES_ADMIN : ROW_GRID_CLASSES_DEFAULT
}
