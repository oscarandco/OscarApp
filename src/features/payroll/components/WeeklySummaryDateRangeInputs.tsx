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
 * Two fixed-width native date inputs (from / to), no heading. Placed in
 * the table toolbar immediately left of the Columns control.
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
    <div className="flex shrink-0 flex-wrap items-center gap-x-2 gap-y-1">
      <input
        type="date"
        value={dateFrom}
        min={dateMin || undefined}
        max={dateMax || undefined}
        onChange={(e) => onDateFromChange(e.target.value)}
        aria-label="From date"
        className="min-w-[10.75rem] max-w-[11.5rem] shrink-0 rounded-md border border-slate-300 bg-white px-2 py-1.5 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
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
        className="min-w-[10.75rem] max-w-[11.5rem] shrink-0 rounded-md border border-slate-300 bg-white px-2 py-1.5 text-sm text-slate-900 shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
        data-testid={dateToTestId}
      />
    </div>
  )
}
