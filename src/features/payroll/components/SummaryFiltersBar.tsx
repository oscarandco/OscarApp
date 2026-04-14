import type { LocationFilterOption } from '@/lib/locationDisplay'

type SummaryFiltersBarProps = {
  locationId: string
  onLocationId: (value: string) => void
  locationOptions: LocationFilterOption[]
  search: string
  onSearch: (value: string) => void
  searchPlaceholder: string
  onReset: () => void
  showReset: boolean
  /** Selects `data-testid`: `payroll-summary-filters` or `admin-summary-filters`. */
  variant: 'stylist' | 'admin'
  /** Weekly payroll: week filter between Location and Search. Omit on admin summary. */
  weekBeginningFilter?: string
  onWeekBeginningFilter?: (value: string) => void
  weekBeginningOptions?: { value: string; label: string }[]
}

/**
 * Client-side filters for weekly summary pages (no network calls).
 */
export function SummaryFiltersBar({
  locationId,
  onLocationId,
  locationOptions,
  search,
  onSearch,
  searchPlaceholder,
  onReset,
  showReset,
  variant,
  weekBeginningFilter = '',
  onWeekBeginningFilter,
  weekBeginningOptions,
}: SummaryFiltersBarProps) {
  const testId =
    variant === 'admin' ? 'admin-summary-filters' : 'payroll-summary-filters'
  const showWeekBeginning =
    weekBeginningOptions != null &&
    onWeekBeginningFilter != null &&
    (variant === 'stylist' || variant === 'admin')

  return (
    <div
      className="mb-5 flex flex-col gap-3 rounded-lg border border-slate-200 bg-slate-50/80 px-3 py-3 sm:flex-row sm:flex-wrap sm:items-end sm:gap-4"
      data-testid={testId}
    >
      <div className="min-w-0 flex-1 sm:max-w-xs">
        <label
          htmlFor={`${testId}-location`}
          className="block text-xs font-medium text-slate-600"
        >
          Location
        </label>
        <select
          id={`${testId}-location`}
          value={locationId}
          onChange={(e) => onLocationId(e.target.value)}
          className="mt-1 w-full rounded-md border border-slate-300 bg-white px-2 py-2 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
        >
          <option value="">All locations</option>
          {locationOptions.map((opt) => (
            <option key={opt.id} value={opt.id}>
              {opt.label}
            </option>
          ))}
        </select>
      </div>
      {showWeekBeginning ? (
        <div className="min-w-0 flex-1 sm:max-w-xs">
          <label
            htmlFor={`${testId}-week-beginning`}
            className="block text-xs font-medium text-slate-600"
          >
            Week beginning
          </label>
          <select
            id={`${testId}-week-beginning`}
            value={weekBeginningFilter}
            onChange={(e) => onWeekBeginningFilter(e.target.value)}
            className="mt-1 w-full rounded-md border border-slate-300 bg-white px-2 py-2 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
            data-testid={`${testId}-week-beginning`}
          >
            <option value="">All weeks</option>
            {weekBeginningOptions.map((opt) => (
              <option key={opt.value} value={opt.value}>
                {opt.label}
              </option>
            ))}
          </select>
        </div>
      ) : null}
      <div className="min-w-0 flex-[2] sm:min-w-[12rem] sm:max-w-md">
        <label
          htmlFor={`${testId}-search`}
          className="block text-xs font-medium text-slate-600"
        >
          Search
        </label>
        <input
          id={`${testId}-search`}
          type="search"
          value={search}
          onChange={(e) => onSearch(e.target.value)}
          placeholder={searchPlaceholder}
          autoComplete="off"
          className="mt-1 w-full rounded-md border border-slate-300 bg-white px-2 py-2 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
        />
      </div>
      {showReset ? (
        <div className="flex sm:pb-0.5">
          <button
            type="button"
            onClick={onReset}
            className="rounded-md border border-slate-300 bg-white px-3 py-2 text-sm font-medium text-slate-800 shadow-sm hover:bg-slate-50"
          >
            Clear filters
          </button>
        </div>
      ) : null}
    </div>
  )
}
