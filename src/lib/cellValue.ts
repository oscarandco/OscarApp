/**
 * Shared guards for table cells — avoids rendering the literal strings "undefined" / "null"
 * and treats blank strings like missing values.
 */

export function isEmptyish(value: unknown): boolean {
  if (value == null) return true
  if (typeof value === 'string') return value.trim() === ''
  if (typeof value === 'number') return Number.isNaN(value)
  return false
}

/** Plain text for primitive cell values (non-money, non-date). */
export function formatScalarText(value: unknown): string {
  if (isEmptyish(value)) return ''
  if (typeof value === 'boolean') return value ? 'Yes' : 'No'
  if (typeof value === 'number' || typeof value === 'bigint') return String(value)
  if (typeof value === 'string') return value.trim()
  if (typeof value === 'symbol') return value.toString()
  return ''
}
