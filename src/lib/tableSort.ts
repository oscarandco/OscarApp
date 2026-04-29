/** Client-side table sort: asc → desc → off (null). */

export type ColumnSortState = { key: string; dir: 'asc' | 'desc' } | null

export function nextColumnSortState(
  prev: ColumnSortState,
  columnKey: string,
): ColumnSortState {
  if (prev == null || prev.key !== columnKey) {
    return { key: columnKey, dir: 'asc' }
  }
  if (prev.dir === 'asc') return { key: columnKey, dir: 'desc' }
  return null
}

export function isBlankSortValue(v: unknown): boolean {
  if (v == null) return true
  if (typeof v === 'string') return v.trim() === ''
  if (typeof v === 'number') return !Number.isFinite(v)
  if (typeof v === 'boolean') return false
  return false
}

function parseSortDate(v: unknown): number {
  if (v == null) return Number.NaN
  const s = String(v).trim()
  if (s === '') return Number.NaN
  const t = Date.parse(s.includes('T') ? s : `${s}T12:00:00`)
  return Number.isNaN(t) ? Number.NaN : t
}

function parseSortNumber(v: unknown): number {
  if (v == null) return Number.NaN
  if (typeof v === 'number') return Number.isFinite(v) ? v : Number.NaN
  if (typeof v === 'boolean') return v ? 1 : 0
  if (typeof v === 'string') {
    const t = v.trim()
    if (t === '') return Number.NaN
    const n = Number(t)
    return Number.isFinite(n) ? n : Number.NaN
  }
  return Number.NaN
}

function compareText(a: unknown, b: unknown): number {
  const sa = String(a ?? '').trim().toLowerCase()
  const sb = String(b ?? '').trim().toLowerCase()
  return sa.localeCompare(sb, undefined, { sensitivity: 'base', numeric: true })
}

/**
 * Compare two scalar cell values for sorting. Blank values sort last in both directions.
 */
export function compareScalarsForSort(
  a: unknown,
  b: unknown,
  kind: 'date' | 'number' | 'text',
  dir: 'asc' | 'desc',
): number {
  const blankA =
    kind === 'date'
      ? Number.isNaN(parseSortDate(a))
      : kind === 'number'
        ? Number.isNaN(parseSortNumber(a))
        : isBlankSortValue(a)
  const blankB =
    kind === 'date'
      ? Number.isNaN(parseSortDate(b))
      : kind === 'number'
        ? Number.isNaN(parseSortNumber(b))
        : isBlankSortValue(b)

  if (blankA && blankB) return 0
  if (blankA) return 1
  if (blankB) return -1

  let c = 0
  if (kind === 'date') {
    c = parseSortDate(a) - parseSortDate(b)
  } else if (kind === 'number') {
    c = parseSortNumber(a) - parseSortNumber(b)
  } else {
    c = compareText(a, b)
  }
  if (c === 0) return 0
  return dir === 'asc' ? c : -c
}

export function stableSorted<T>(
  rows: T[],
  compare: (a: T, b: T) => number,
): T[] {
  return [...rows]
    .map((row, index) => ({ row, index }))
    .sort((x, y) => {
      const c = compare(x.row, y.row)
      if (c !== 0) return c
      return x.index - y.index
    })
    .map((x) => x.row)
}
