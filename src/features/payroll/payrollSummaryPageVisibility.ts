import type { RoleKey } from '@/features/access/pageAccess'
import type { MiddleColumnId } from '@/features/payroll/weeklySummaryTableColumns'

/**
 * Centralised role-based visibility rules for the My Sales page.
 *
 * The matrix here is the single source of truth for every role-driven
 * UI decision on `PayrollSummaryPage`:
 *
 *   • which filters render (Search, Location)
 *   • which summary cards render (Commission earnt, Sales)
 *   • which table middle columns are force-hidden regardless of the
 *     stored column-picker preferences (Staff Paid, Potential
 *     Commission, Commission payable)
 *
 * Role mapping note — the spec uses the label "apprentice" but the
 * stored access role in the database / `RoleKey` type is `assistant`.
 * We treat them as the same: see `mySalesVisibilityForRole('assistant')`.
 *
 * This helper does NOT decide whether the page is reachable at all —
 * `RequirePageAccess pageId="my_payroll"` already gates that via the
 * shared access matrix in `@/features/access/pageAccess`.
 */
export type MySalesVisibility = {
  /** Search input in the filter bar. */
  showSearchFilter: boolean
  /** Location dropdown in the filter bar. */
  showLocationFilter: boolean
  /** "Commission earnt" summary card. */
  showCommissionCard: boolean
  /** "Sales (ex GST)" summary card. */
  showSalesCard: boolean
  /**
   * "Rows shown" summary card. Hidden for stylist / assistant — the
   * same figure is already shown in the diagnostics line above the
   * table, and the simplified stylist/assistant view does not need a
   * second copy. Manager / admin keep it.
   */
  showRowsShownCard: boolean
  /**
   * `Columns` button (the column-picker trigger above the table). Hidden
   * for stylist / assistant — those roles get a fixed, role-tailored
   * column set and re-ordering / hiding columns themselves would just
   * confuse the simplified view. Manager / admin keep it.
   */
  showColumnPicker: boolean
  /**
   * Middle table columns that must be hidden for this role on My Sales,
   * regardless of any saved column-picker preference. Layered on top of
   * the user's `prefs.hidden` set inside `WeeklySummaryTable` /
   * `visibleMiddleColumns`. Returned as a fresh `Set` per call so
   * callers can extend it (e.g. add `'location'` when the Summary rows
   * toggle is set to "Combined").
   */
  hiddenTableColumnIds: Set<MiddleColumnId>
  /**
   * Per-role overrides for the column header labels. Keys are
   * `MiddleColumnId`s; only the columns named here use the override
   * label, every other column falls back to the global `COLUMN_LABEL`.
   * Used to give stylist/assistant their shorter, simplified header
   * names (e.g. `Commission` instead of `Commission payable (ex GST)`)
   * without changing the global default that admin pages still rely
   * on. Returned as a fresh object per call.
   */
  columnLabelOverrides: Partial<Record<MiddleColumnId, string>>
}

/**
 * Returns the My Sales visibility config for the given role. Unknown
 * / null roles fall through to the most restrictive (`assistant`)
 * preset; the page itself will still 404 / redirect via
 * `RequirePageAccess` before the user can see anything.
 */
export function mySalesVisibilityForRole(
  role: RoleKey | null,
): MySalesVisibility {
  switch (role) {
    case 'admin':
    case 'manager':
      return {
        showSearchFilter: true,
        showLocationFilter: true,
        showCommissionCard: true,
        showSalesCard: true,
        showRowsShownCard: true,
        showColumnPicker: true,
        // Manager/Admin see all role-gated middle columns (Staff Paid,
        // Potential Commission, Commission payable). `pay_date` is the
        // only column hard-removed across every role on My Sales (see
        // requirements: "remove these columns entirely: Pay Week, Pay
        // Date" — Pay Week is a fixed outer column and is removed at
        // the table layer; Pay Date is a middle column and is hidden
        // here so it never re-appears via stored preferences).
        hiddenTableColumnIds: new Set<MiddleColumnId>(['pay_date']),
        // No header overrides — manager/admin keep the global default
        // labels from `COLUMN_LABEL` so admin pages render unchanged.
        columnLabelOverrides: {},
      }
    case 'stylist':
      return {
        showSearchFilter: false,
        showLocationFilter: false,
        showCommissionCard: true,
        showSalesCard: false,
        showRowsShownCard: false,
        showColumnPicker: false,
        // Stylists hide Pay Date, Staff Paid AND Potential Commission;
        // their Commission Payable column is then renamed to just
        // `Commission` via the overrides below.
        hiddenTableColumnIds: new Set<MiddleColumnId>([
          'pay_date',
          'derived_staff_paid_full_name',
          'total_theoretical_commission_ex_gst',
        ]),
        columnLabelOverrides: {
          total_actual_commission_ex_gst: 'Commission',
          total_sales_ex_gst: 'Sales (ex GST)',
        },
      }
    case 'assistant':
    default:
      return {
        showSearchFilter: false,
        showLocationFilter: false,
        showCommissionCard: false,
        showSalesCard: false,
        showRowsShownCard: false,
        showColumnPicker: false,
        // Assistant now sees Potential Commission (renamed via override
        // below) but still hides Commission Payable + Staff Paid + Pay
        // Date.
        hiddenTableColumnIds: new Set<MiddleColumnId>([
          'pay_date',
          'derived_staff_paid_full_name',
          'total_actual_commission_ex_gst',
        ]),
        columnLabelOverrides: {
          total_theoretical_commission_ex_gst: 'Potential Commission',
          total_sales_ex_gst: 'Sales (ex GST)',
        },
      }
  }
}
