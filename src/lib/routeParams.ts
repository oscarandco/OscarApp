/**
 * `:payWeekStart` route segment — must match what the RPC expects (typically `YYYY-MM-DD`).
 */

export type PayWeekRouteResult =
  | { kind: 'missing' }
  | { kind: 'invalid'; reason: string; rawDisplay: string }
  | { kind: 'ok'; value: string }

const ISO_DATE_PREFIX = /^\d{4}-\d{2}-\d{2}/

/**
 * Decode and validate the pay-week URL param.
 * Returns `ok` only when the value looks like a real calendar date string.
 */
export function parsePayWeekRouteParam(raw: string | undefined): PayWeekRouteResult {
  if (raw == null || String(raw).trim() === '') {
    return { kind: 'missing' }
  }

  let decoded: string
  try {
    decoded = decodeURIComponent(String(raw).trim())
  } catch {
    return {
      kind: 'invalid',
      reason: 'The link could not be read. Open a week from the summary table.',
      rawDisplay: truncateDisplay(String(raw)),
    }
  }

  if (decoded.length > 120) {
    return {
      kind: 'invalid',
      reason: 'That URL segment is not a valid pay week key.',
      rawDisplay: truncateDisplay(decoded),
    }
  }

  if (!ISO_DATE_PREFIX.test(decoded)) {
    return {
      kind: 'invalid',
      reason:
        'Expected a pay week start date (for example YYYY-MM-DD). Use the links from the weekly summary.',
      rawDisplay: decoded,
    }
  }

  const parseable = decoded.includes('T') ? decoded : `${decoded}T12:00:00`
  const t = Date.parse(parseable)
  if (Number.isNaN(t)) {
    return {
      kind: 'invalid',
      reason: 'That date is not valid. Choose a week from the weekly summary.',
      rawDisplay: decoded,
    }
  }

  return { kind: 'ok', value: decoded }
}

function truncateDisplay(s: string, max = 64): string {
  if (s.length <= max) return s
  return `${s.slice(0, max)}…`
}
