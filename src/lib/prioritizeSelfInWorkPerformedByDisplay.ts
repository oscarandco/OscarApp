/**
 * Display-only: if a comma-separated token matches the logged-in stylist
 * (by display/full name, case-insensitive), move that token to the front
 * while preserving relative order of the others.
 */
export function prioritizeSelfInWorkPerformedByDisplay(
  commaSeparated: string,
  matchNames: readonly string[],
): string {
  const trimmed = commaSeparated.trim()
  if (trimmed === '') return trimmed

  const parts = trimmed
    .split(',')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
  if (parts.length === 0) return trimmed
  if (parts.length < 2) return parts.join(', ')

  const normalizedMatches = new Set<string>()
  for (const m of matchNames) {
    const t = m.trim()
    if (!t) continue
    normalizedMatches.add(t.toLowerCase())
    const first = t.split(/\s+/)[0] ?? ''
    if (first) normalizedMatches.add(first.toLowerCase())
  }
  if (normalizedMatches.size === 0) return parts.join(', ')

  let idx = -1
  for (let i = 0; i < parts.length; i++) {
    if (normalizedMatches.has(parts[i].toLowerCase())) {
      idx = i
      break
    }
  }
  if (idx <= 0) return parts.join(', ')

  const next = [...parts]
  const [self] = next.splice(idx, 1)
  return [self, ...next].join(', ')
}
