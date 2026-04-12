/** Prefer human-readable location from RPC row; fall back to id for filters/keys. */
export function locationLabelFromRow(row: {
  location_name?: string | null
  location_id?: string | null
}): string {
  const name = row.location_name
  if (name != null && String(name).trim() !== '') return String(name).trim()
  const id = row.location_id
  if (id != null && String(id).trim() !== '') return String(id).trim()
  return '—'
}

export type LocationFilterOption = { id: string; label: string }
