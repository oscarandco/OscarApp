import { useCallback, useState } from 'react'

import {
  defaultAdminColumnPreferences,
  loadAdminColumnPreferences,
  saveAdminColumnPreferences,
  type AdminColumnPreferences,
} from '@/features/admin/adminWeeklySummaryTableColumns'

export function useAdminPayrollSummaryColumnPreferences(): {
  prefs: AdminColumnPreferences
  setPrefs: (
    next:
      | AdminColumnPreferences
      | ((prev: AdminColumnPreferences) => AdminColumnPreferences),
  ) => void
  reset: () => void
} {
  const [prefs, setPrefsState] = useState<AdminColumnPreferences>(() =>
    loadAdminColumnPreferences(),
  )

  const setPrefs = useCallback(
    (
      next:
        | AdminColumnPreferences
        | ((prev: AdminColumnPreferences) => AdminColumnPreferences),
    ) => {
      setPrefsState((prev) => {
        const n = typeof next === 'function' ? next(prev) : next
        saveAdminColumnPreferences(n)
        return n
      })
    },
    [],
  )

  const reset = useCallback(() => {
    const d = defaultAdminColumnPreferences()
    setPrefsState(d)
    saveAdminColumnPreferences(d)
  }, [])

  return { prefs, setPrefs, reset }
}
