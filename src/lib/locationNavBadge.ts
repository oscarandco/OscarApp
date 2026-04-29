import type { ImportLocationRow } from '@/lib/supabaseRpc'

/** Orewa / Takapuna only; same rules as Staff Admin primary location (code or name). */
export function primaryLocationNavBadge(
  primaryLocationId: string | null | undefined,
  locations: ImportLocationRow[],
): 'O' | 'T' | null {
  const id = primaryLocationId?.trim()
  if (!id) return null
  const loc = locations.find((l) => l.id === id)
  if (!loc) return null
  const code = (loc.code ?? '').trim().toUpperCase()
  if (code === 'ORE') return 'O'
  if (code === 'TAK') return 'T'
  const n = (loc.name ?? '').trim().toLowerCase()
  if (n.includes('orewa')) return 'O'
  if (n.includes('takapuna')) return 'T'
  return null
}

/**
 * Single-salon badge for payroll aggregates: only when every contributing line
 * shares one location id (resolved via `locations`) or one distinct non-empty
 * location name (Orewa / Takapuna substring). Mixed or empty → no badge.
 */
export function badgeForPayrollStaffBucket(
  locationIds: ReadonlySet<string>,
  locationNamesLower: ReadonlySet<string>,
  locations: ImportLocationRow[],
): 'O' | 'T' | null {
  if (locationIds.size === 1) {
    const b = primaryLocationNavBadge([...locationIds][0], locations)
    if (b) return b
  }
  if (locationNamesLower.size === 1) {
    const n = [...locationNamesLower][0]
    if (n.includes('orewa')) return 'O'
    if (n.includes('takapuna')) return 'T'
  }
  return null
}
