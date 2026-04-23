import type { StaffMemberSearchRow } from '@/features/admin/types/accessManagement'
import type { KpiSnapshotScope } from '@/features/kpi/data/kpiApi'
import type { ImportLocationRow } from '@/lib/supabaseRpc'

/** Controlled state owned by the dashboard page. */
export type KpiFiltersValue = {
  /** ISO `YYYY-MM-01`. */
  periodStart: string
  scope: KpiSnapshotScope
  locationId: string
  staffMemberId: string
}

type Props = {
  value: KpiFiltersValue
  onChange: (next: KpiFiltersValue) => void
  /** When false (stylist / assistant), only the month picker is shown. */
  elevated: boolean
  locations: ImportLocationRow[]
  locationsLoading: boolean
  staff: StaffMemberSearchRow[]
  staffLoading: boolean
  disabled?: boolean
}

function firstOfMonthForInput(periodStart: string): string {
  // <input type="month"> expects YYYY-MM; state keeps YYYY-MM-01.
  return periodStart.slice(0, 7)
}

function staffLabel(row: StaffMemberSearchRow): string {
  return row.display_name?.trim() || row.full_name?.trim() || row.staff_member_id
}

/**
 * Compact filters bar for the KPI dashboard.
 *
 * Layout: column stack on mobile, wraps to a row with `sm:flex-wrap`
 * so two filters fit side-by-side on tablets and all four (month +
 * scope + location/staff) fit on one line on desktop. Individual
 * controls use `min-w-[10rem]` so labels never collapse.
 *
 * Non-elevated users only see the month picker — the parent still
 * drives their scope to `'staff'` via the effective-scope derivation
 * so no server-enforced restriction is bypassed in the UI.
 */
export function KpiFiltersBar({
  value,
  onChange,
  elevated,
  locations,
  locationsLoading,
  staff,
  staffLoading,
  disabled,
}: Props) {
  const monthInputValue = firstOfMonthForInput(value.periodStart)

  function patch(patchValue: Partial<KpiFiltersValue>) {
    onChange({ ...value, ...patchValue })
  }

  function handleMonthChange(e: React.ChangeEvent<HTMLInputElement>) {
    const raw = e.target.value
    if (!raw) return // ignore "clear" — keep last valid month
    // raw is YYYY-MM
    patch({ periodStart: `${raw}-01` })
  }

  function handleScopeChange(e: React.ChangeEvent<HTMLSelectElement>) {
    const next = e.target.value as KpiSnapshotScope
    // Reset scope-specific ids when leaving a scope so a stale id
    // never travels to the RPC on a scope switch.
    patch({
      scope: next,
      locationId: next === 'location' ? value.locationId : '',
      staffMemberId: next === 'staff' ? value.staffMemberId : '',
    })
  }

  const selectClass =
    'mt-1 block w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500 disabled:opacity-50'

  return (
    <div
      className="mb-4 flex flex-col gap-3 sm:mb-5 sm:flex-row sm:flex-wrap sm:items-end"
      data-testid="kpi-filters-bar"
    >
      <div className="w-full sm:w-auto sm:min-w-[10rem]">
        <label
          htmlFor="kpi-filter-month"
          className="block text-xs font-medium text-slate-600"
        >
          Month
        </label>
        <input
          id="kpi-filter-month"
          type="month"
          value={monthInputValue}
          onChange={handleMonthChange}
          disabled={disabled}
          className={selectClass}
          data-testid="kpi-filter-month"
        />
      </div>

      {elevated ? (
        <div className="w-full sm:w-auto sm:min-w-[10rem]">
          <label
            htmlFor="kpi-filter-scope"
            className="block text-xs font-medium text-slate-600"
          >
            Scope
          </label>
          <select
            id="kpi-filter-scope"
            value={value.scope}
            onChange={handleScopeChange}
            disabled={disabled}
            className={selectClass}
            data-testid="kpi-filter-scope"
          >
            <option value="business">Business</option>
            <option value="location">Location</option>
            <option value="staff">Staff</option>
          </select>
        </div>
      ) : null}

      {elevated && value.scope === 'location' ? (
        <div className="w-full sm:w-auto sm:min-w-[14rem]">
          <label
            htmlFor="kpi-filter-location"
            className="block text-xs font-medium text-slate-600"
          >
            Location
          </label>
          <select
            id="kpi-filter-location"
            value={value.locationId}
            onChange={(e) => patch({ locationId: e.target.value })}
            disabled={disabled || locationsLoading}
            className={selectClass}
            data-testid="kpi-filter-location"
          >
            <option value="">
              {locationsLoading ? 'Loading locations…' : 'Select location…'}
            </option>
            {locations.map((loc) => (
              <option key={loc.id} value={loc.id}>
                {loc.name} ({loc.code})
              </option>
            ))}
          </select>
        </div>
      ) : null}

      {elevated && value.scope === 'staff' ? (
        <div className="w-full sm:w-auto sm:min-w-[14rem]">
          <label
            htmlFor="kpi-filter-staff"
            className="block text-xs font-medium text-slate-600"
          >
            Staff
          </label>
          <select
            id="kpi-filter-staff"
            value={value.staffMemberId}
            onChange={(e) => patch({ staffMemberId: e.target.value })}
            disabled={disabled || staffLoading}
            className={selectClass}
            data-testid="kpi-filter-staff"
          >
            <option value="">
              {staffLoading ? 'Loading staff…' : 'Select staff…'}
            </option>
            {staff.map((row) => (
              <option key={row.staff_member_id} value={row.staff_member_id}>
                {staffLabel(row)}
              </option>
            ))}
          </select>
        </div>
      ) : null}
    </div>
  )
}
