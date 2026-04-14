import { useCallback, useState } from 'react'

import {
  defaultLineTablePreferences,
  loadLineTablePreferences,
  saveLineTablePreferences,
  type LineTablePreferences,
} from '@/features/payroll/payrollLineTableColumns'

export function usePayrollLineColumnPreferences(): {
  prefs: LineTablePreferences
  setPrefs: (
    next: LineTablePreferences | ((prev: LineTablePreferences) => LineTablePreferences),
  ) => void
  reset: () => void
} {
  const [prefs, setPrefsState] = useState<LineTablePreferences>(() =>
    loadLineTablePreferences(),
  )

  const setPrefs = useCallback(
    (
      next:
        | LineTablePreferences
        | ((prev: LineTablePreferences) => LineTablePreferences),
    ) => {
      setPrefsState((prev) => {
        const n = typeof next === 'function' ? next(prev) : next
        saveLineTablePreferences(n)
        return n
      })
    },
    [],
  )

  const reset = useCallback(() => {
    const d = defaultLineTablePreferences()
    setPrefsState(d)
    saveLineTablePreferences(d)
  }, [])

  return { prefs, setPrefs, reset }
}
