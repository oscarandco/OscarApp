import { useCallback, useState } from 'react'

import {
  defaultColumnPreferences,
  loadColumnPreferences,
  saveColumnPreferences,
  type ColumnPreferences,
} from '@/features/payroll/weeklySummaryTableColumns'

export function usePayrollSummaryColumnPreferences(): {
  prefs: ColumnPreferences
  setPrefs: (next: ColumnPreferences | ((prev: ColumnPreferences) => ColumnPreferences)) => void
  reset: () => void
} {
  const [prefs, setPrefsState] = useState<ColumnPreferences>(() =>
    loadColumnPreferences(),
  )

  const setPrefs = useCallback(
    (
      next:
        | ColumnPreferences
        | ((prev: ColumnPreferences) => ColumnPreferences),
    ) => {
      setPrefsState((prev) => {
        const n = typeof next === 'function' ? next(prev) : next
        saveColumnPreferences(n)
        return n
      })
    },
    [],
  )

  const reset = useCallback(() => {
    const d = defaultColumnPreferences()
    setPrefsState(d)
    saveColumnPreferences(d)
  }, [])

  return { prefs, setPrefs, reset }
}
