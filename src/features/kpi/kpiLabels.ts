import { formatNzd } from '@/lib/formatters'

/**
 * Per-KPI display metadata used by the dashboard cards. Kept as a
 * plain record so new KPIs can be added without touching the UI
 * components.
 *
 *   label   — human-friendly heading shown on the card.
 *   format  — how to render `value`, plus which supporting-text
 *             renderer to use for numerator / denominator.
 *   order   — display order on the grid (lower = earlier).
 *
 * `format` values:
 *   'currency'      — render value as NZD (no denominator text).
 *   'count'         — render value as a whole number (no denominator).
 *   'percent'       — render value × 100 with 1 dp, supporting text
 *                     shows `retained X of Y` when denominator > 0.
 *   'decimal'       — render value to 2 dp, supporting text shows
 *                     `X visits across Y clients`.
 *   'nzd_per_fte'   — render value as NZD, supporting text shows
 *                     `$X / Y.Y FTE`.
 *   'nzd_per_guest' — render value as NZD, supporting text shows
 *                     `$X across Y guests`.
 *   'assist_ratio'  — render value × 100, supporting text shows
 *                     assistant-helped vs total sales ex GST.
 */
export type KpiFormat =
  | 'currency'
  | 'count'
  | 'percent'
  | 'decimal'
  | 'nzd_per_fte'
  | 'nzd_per_guest'
  | 'assist_ratio'

export type KpiMeta = {
  label: string
  format: KpiFormat
  order: number
}

export const KPI_DISPLAY_META: Record<string, KpiMeta> = {
  revenue: { label: 'Revenue', format: 'currency', order: 10 },
  guests_per_month: { label: 'Guests', format: 'count', order: 20 },
  new_clients_per_month: {
    label: 'New clients',
    format: 'count',
    order: 30,
  },
  average_client_spend: {
    label: 'Average client spend',
    format: 'nzd_per_guest',
    order: 40,
  },
  client_frequency: {
    label: 'Client frequency',
    format: 'decimal',
    order: 50,
  },
  client_retention_6m: {
    label: 'Client retention (6m)',
    format: 'percent',
    order: 60,
  },
  client_retention_12m: {
    label: 'Client retention (12m)',
    format: 'percent',
    order: 70,
  },
  new_client_retention_6m: {
    label: 'New-client retention (6m)',
    format: 'percent',
    order: 80,
  },
  new_client_retention_12m: {
    label: 'New-client retention (12m)',
    format: 'percent',
    order: 90,
  },
  assistant_utilisation_ratio: {
    label: 'Assistant utilisation',
    format: 'assist_ratio',
    order: 100,
  },
  stylist_profitability: {
    label: 'Stylist profitability',
    format: 'nzd_per_fte',
    order: 110,
  },
}

/** Falls back to a title-cased `kpi_code` when no mapping is found. */
export function metaFor(kpiCode: string): KpiMeta {
  const exact = KPI_DISPLAY_META[kpiCode]
  if (exact) return exact
  const fallback = kpiCode
    .replace(/_/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase())
  return { label: fallback, format: 'decimal', order: 999 }
}

function toNumber(v: number | string | null | undefined): number | null {
  if (v == null || v === '') return null
  const n = typeof v === 'number' ? v : Number(v)
  return Number.isFinite(n) ? n : null
}

const wholeNumberFormatter = new Intl.NumberFormat('en-NZ', {
  maximumFractionDigits: 0,
})
const decimalFormatter = new Intl.NumberFormat('en-NZ', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2,
})
const fteFormatter = new Intl.NumberFormat('en-NZ', {
  minimumFractionDigits: 1,
  maximumFractionDigits: 2,
})
const percentFormatter = new Intl.NumberFormat('en-NZ', {
  minimumFractionDigits: 1,
  maximumFractionDigits: 1,
})

/**
 * Render the main value shown in large type on the card. Returns `—`
 * when the backend set `value` to NULL (e.g. percent KPIs with a
 * zero-cohort denominator).
 */
export function formatKpiValue(
  format: KpiFormat,
  value: number | string | null,
): string {
  const n = toNumber(value)
  if (n == null) return '—'
  switch (format) {
    case 'currency':
    case 'nzd_per_fte':
    case 'nzd_per_guest':
      return formatNzd(n)
    case 'count':
      return wholeNumberFormatter.format(Math.round(n))
    case 'percent':
    case 'assist_ratio':
      return `${percentFormatter.format(n * 100)}%`
    case 'decimal':
    default:
      return decimalFormatter.format(n)
  }
}

/**
 * Small supporting-text line shown beneath the big value. Keeps the
 * grid compact: returns `null` when there is nothing meaningful to
 * add (e.g. a plain currency KPI). When the denominator is zero we
 * return a short explanation so cards with `value = —` still read
 * correctly.
 */
export function formatKpiSupporting(
  format: KpiFormat,
  numerator: number | string | null,
  denominator: number | string | null,
): string | null {
  const num = toNumber(numerator)
  const den = toNumber(denominator)

  switch (format) {
    case 'currency':
    case 'count':
      return null
    case 'percent': {
      if (den == null) return null
      if (den === 0) return 'No clients in base cohort'
      const retained = num ?? 0
      return `Retained ${wholeNumberFormatter.format(
        Math.round(retained),
      )} of ${wholeNumberFormatter.format(Math.round(den))}`
    }
    case 'decimal': {
      if (num == null && den == null) return null
      if (den === 0 || den == null) return 'No clients in window'
      return `${wholeNumberFormatter.format(
        Math.round(num ?? 0),
      )} visits across ${wholeNumberFormatter.format(
        Math.round(den),
      )} clients`
    }
    case 'nzd_per_guest': {
      if (den == null) return null
      if (den === 0) return 'No guests in period'
      return `${formatNzd(num ?? 0)} across ${wholeNumberFormatter.format(
        Math.round(den),
      )} guests`
    }
    case 'nzd_per_fte': {
      if (den == null) return null
      if (den === 0) return 'No eligible FTE'
      return `${formatNzd(num ?? 0)} across ${fteFormatter.format(
        den,
      )} FTE`
    }
    case 'assist_ratio': {
      if (den == null) return null
      if (den === 0) return 'No eligible sales'
      return `${formatNzd(num ?? 0)} of ${formatNzd(den)} ex GST`
    }
    default:
      return null
  }
}

/** Stable sort helper for rendering cards in the matrix order. */
export function kpiSortComparator(a: string, b: string): number {
  return metaFor(a).order - metaFor(b).order
}
