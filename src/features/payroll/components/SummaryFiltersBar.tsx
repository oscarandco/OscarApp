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
  /** Combined = one row per staff + week across sites; split = per location. */
  splitByLocation?: boolean
  onSplitByLocationChange?: (splitByLocation: boolean) => void
  /**
   * Mount the Search field. Defaults to `true` so the admin variant
   * keeps its existing layout. Stylist / assistant My Sales hides it
   * by passing `false`.
   */
  showSearch?: boolean
  /**
   * Mount the Location dropdown. Defaults to `true` for the same
   * reason. Stylist / assistant My Sales hides it by passing `false`.
   */
  showLocation?: boolean
  /**
   * Optional date-range filter (YYYY-MM-DD strings). Renders to the
   * LEFT of the Location dropdown when both `dateFrom` / `dateTo`
   * setters are provided. `dateMin` / `dateMax` are applied as the
   * input `min` / `max` attributes so the picker is bounded by the
   * data extents — users can extend back to `dateMin` to see the
   * full available range.
   *
   * Used by My Sales to scope the displayed weekly summary rows
   * (and the per-location sales tiles) to the selected window.
   */
  dateFrom?: string
  dateTo?: string
  onDateFromChange?: (value: string) => void
  onDateToChange?: (value: string) => void
  dateMin?: string
  dateMax?: string
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
  splitByLocation = false,
  onSplitByLocationChange,
  showSearch = true,
  showLocation = true,
  dateFrom,
  dateTo,
  onDateFromChange,
  onDateToChange,
  dateMin,
  dateMax,
}: SummaryFiltersBarProps) {
  const testId =
    variant === 'admin' ? 'admin-summary-filters' : 'payroll-summary-filters'
  const showWeekBeginning =
    weekBeginningOptions != null &&
    onWeekBeginningFilter != null &&
    (variant === 'stylist' || variant === 'admin')
  const showDateRange =
    onDateFromChange != null && onDateToChange != null

  return (
    <div
      className="mb-4 flex flex-col gap-2 rounded-lg border border-slate-200 bg-slate-50/80 px-2.5 py-2.5 sm:mb-5 sm:flex-row sm:flex-wrap sm:items-end sm:gap-4 sm:px-3 sm:py-3"
      data-testid={testId}
    >
      {showDateRange ? (
        <div className="min-w-0 flex-1 sm:max-w-md">
          <span className="block text-xs font-medium text-slate-600">
            Date range
          </span>
          <div className="mt-1 flex items-center gap-2">
            <input
              type="date"
              value={dateFrom ?? ''}
              min={dateMin || undefined}
              max={dateMax || undefined}
              onChange={(e) => onDateFromChange(e.target.value)}
              aria-label="From date"
              className="w-full rounded-md border border-slate-300 bg-white px-2 py-2 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
              data-testid={`${testId}-date-from`}
            />
            <span className="text-xs text-slate-500">to</span>
            <input
              type="date"
              value={dateTo ?? ''}
              min={dateMin || undefined}
              max={dateMax || undefined}
              onChange={(e) => onDateToChange(e.target.value)}
              aria-label="To date"
              className="w-full rounded-md border border-slate-300 bg-white px-2 py-2 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
              data-testid={`${testId}-date-to`}
            />
          </div>
        </div>
      ) : null}
      {showLocation ? (
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
      ) : null}
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
      {showSearch ? (
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
      ) : null}
      {onSplitByLocationChange != null ? (
        <div className="shrink-0">
          <span className="block text-xs font-medium text-slate-600">Summary rows</span>
          <div
            className="mt-1 inline-flex rounded-lg border border-slate-300 bg-slate-100/90 p-0.5 shadow-sm"
            role="group"
            aria-label="Combine or split summary rows by location"
          >
            <button
              type="button"
              className={`rounded-md px-3 py-2 text-sm font-medium transition focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1 ${
                !splitByLocation
                  ? 'bg-white text-slate-900 shadow-sm ring-1 ring-slate-200/90'
                  : 'text-slate-600 hover:bg-white/70 hover:text-slate-900'
              }`}
              onClick={() => onSplitByLocationChange(false)}
              data-testid={`${testId}-summary-rows-combined`}
              aria-pressed={!splitByLocation}
            >
              Combined
            </button>
            <button
              type="button"
              className={`rounded-md px-3 py-2 text-sm font-medium transition focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1 ${
                splitByLocation
                  ? 'bg-white text-slate-900 shadow-sm ring-1 ring-slate-200/90'
                  : 'text-slate-600 hover:bg-white/70 hover:text-slate-900'
              }`}
              onClick={() => onSplitByLocationChange(true)}
              data-testid={`${testId}-summary-rows-split`}
              aria-pressed={splitByLocation}
            >
              Split by location
            </button>
          </div>
        </div>
      ) : null}
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
