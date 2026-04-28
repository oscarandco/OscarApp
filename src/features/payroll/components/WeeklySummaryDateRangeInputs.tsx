type WeeklySummaryDateRangeInputsProps = {
  dateFrom: string
  dateTo: string
  onDateFromChange: (value: string) => void
  onDateToChange: (value: string) => void
  dateMin?: string
  dateMax?: string
  dateFromTestId: string
  dateToTestId: string
}

/**
 * Two fixed-width native date inputs for the sales reporting toolbar.
 * Sits to the left of data-source lines and the Columns control.
 */
export function WeeklySummaryDateRangeInputs({
  dateFrom,
  dateTo,
  onDateFromChange,
  onDateToChange,
  dateMin,
  dateMax,
  dateFromTestId,
  dateToTestId,
}: WeeklySummaryDateRangeInputsProps) {
  return (
    <div className="shrink-0">
      <span className="block text-xs font-medium text-slate-600">
        Date range
      </span>
      <div className="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1">
        <input
          type="date"
          value={dateFrom}
          min={dateMin || undefined}
          max={dateMax || undefined}
          onChange={(e) => onDateFromChange(e.target.value)}
          aria-label="From date"
          className="min-w-[10.75rem] max-w-[11.5rem] shrink-0 rounded-md border border-slate-300 bg-white px-2 py-2 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
          data-testid={dateFromTestId}
        />
        <span className="shrink-0 text-xs font-medium text-slate-500">to</span>
        <input
          type="date"
          value={dateTo}
          min={dateMin || undefined}
          max={dateMax || undefined}
          onChange={(e) => onDateToChange(e.target.value)}
          aria-label="To date"
          className="min-w-[10.75rem] max-w-[11.5rem] shrink-0 rounded-md border border-slate-300 bg-white px-2 py-2 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
          data-testid={dateToTestId}
        />
      </div>
    </div>
  )
}
