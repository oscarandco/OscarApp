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

/**
 * Optional per-KPI overrides for the drilldown table header. Any
 * label left undefined falls back to the generic column name
 * ("Primary", "Secondary", "Metric 1", "Metric 2") so the table
 * still reads sensibly for KPIs without bespoke wording.
 *
 * `guestNameColumn` marks the column that holds the guest identity.
 * The drilldown renderer title-cases that cell (e.g. `janet russel`
 * → `Janet Russel`) and, if no explicit label override is set, uses
 * the shared "Guest Name" column title instead of "Primary" /
 * "Secondary". Only `'primary'` is used today — the backend always
 * surfaces the client name in `primary_label` — but the shape is
 * kept open in case a future KPI needs the guest in `secondary`.
 *
 * `hideSecondary` drops the secondary column from the generic table
 * entirely. Used to collapse KPIs whose `secondary_label` is just a
 * duplicate of the primary guest name (e.g. Guests, New clients,
 * Average client spend, Client frequency — where the backend sends
 * the raw-name sample in `secondary_label` alongside the normalised
 * name in `primary_label`). Ignored by the retention table which has
 * its own bespoke column layout.
 */
export type KpiDrilldownColumnOverrides = {
  primary?: string
  secondary?: string
  metric1?: string
  metric2?: string
  guestNameColumn?: 'primary'
  hideSecondary?: boolean
}

export type KpiMeta = {
  label: string
  /** Short plain-English blurb rendered between the title and the value. */
  description: string
  format: KpiFormat
  order: number
  /** Optional column-header overrides for `KpiDrilldownTable`. */
  drilldown?: KpiDrilldownColumnOverrides
}

export const KPI_DISPLAY_META: Record<string, KpiMeta> = {
  revenue: {
    label: 'Revenue',
    description: 'Total sales ex GST for the selected period.',
    format: 'currency',
    order: 10,
    drilldown: {
      secondary: 'Stylist',
      metric1: 'Sales ex GST',
      guestNameColumn: 'primary',
    },
  },
  guests_per_month: {
    label: 'Guests',
    description: 'Distinct guests seen in the selected period.',
    format: 'count',
    order: 20,
    drilldown: {
      metric1: 'Visits',
      metric2: 'Spend',
      guestNameColumn: 'primary',
      hideSecondary: true,
    },
  },
  new_clients_per_month: {
    label: 'New guests',
    description:
      'Guests first seen in the business during the selected period.',
    format: 'count',
    order: 30,
    drilldown: {
      metric1: 'Visits',
      metric2: 'Spend',
      guestNameColumn: 'primary',
      hideSecondary: true,
    },
  },
  average_client_spend: {
    label: 'Average guest spend',
    description: 'Average sales ex GST per guest in the selected period.',
    format: 'nzd_per_guest',
    order: 40,
    drilldown: {
      metric1: 'Spend',
      metric2: 'Visits',
      guestNameColumn: 'primary',
      hideSecondary: true,
    },
  },
  client_frequency: {
    label: 'Guest frequency',
    description: 'Average visits per distinct guest over the past 12 months.',
    format: 'decimal',
    order: 50,
    drilldown: {
      metric1: 'Visits',
      guestNameColumn: 'primary',
      hideSecondary: true,
    },
  },
  client_retention_6m: {
    label: 'Guest retention (6m)',
    description:
      'Share of guests from the first half of the past 6 months who returned and were served by anyone in the second.',
    format: 'percent',
    order: 60,
    drilldown: {
      secondary: 'Retention status',
      metric1: 'Retained',
      guestNameColumn: 'primary',
    },
  },
  client_retention_12m: {
    label: 'Guest retention (12m)',
    description:
      'Share of guests from the first half of the past 12 months who returned and were served by anyone in the second.',
    format: 'percent',
    order: 70,
    drilldown: {
      secondary: 'Retention status',
      metric1: 'Retained',
      guestNameColumn: 'primary',
    },
  },
  new_client_retention_6m: {
    label: 'New-guest retention (6m)',
    description:
      'Share of guests who were new to Oscar & Co and served in the first half of the past 6 months, who returned and were served by anyone in the second.',
    format: 'percent',
    order: 80,
    drilldown: {
      secondary: 'Retention status',
      metric1: 'Retained',
      guestNameColumn: 'primary',
    },
  },
  new_client_retention_12m: {
    label: 'New-guest retention (12m)',
    description:
      'Share of guests who were new to Oscar & Co and served in the first half of the past 12 months, who returned and were served by anyone in the second.',
    format: 'percent',
    order: 90,
    drilldown: {
      secondary: 'Retention status',
      metric1: 'Retained',
      guestNameColumn: 'primary',
    },
  },
  assistant_utilisation_ratio: {
    label: 'Assistant utilisation',
    description:
      'Share of eligible sales where a waged assistant performed the work for a stylist-owned line.',
    format: 'assist_ratio',
    order: 100,
    drilldown: {
      secondary: 'Assistant / owner context',
      metric1: 'Sales ex GST',
      metric2: 'Counted in numerator',
      guestNameColumn: 'primary',
    },
  },
  stylist_profitability: {
    label: 'Stylist profitability',
    description: 'Revenue ex GST per FTE stylist in the selected period.',
    format: 'nzd_per_fte',
    order: 110,
    drilldown: {
      primary: 'Staff member',
      secondary: 'FTE context',
      metric1: 'Revenue ex GST',
      metric2: 'FTE',
    },
  },
}

/** Falls back to a title-cased `kpi_code` when no mapping is found. */
export function metaFor(kpiCode: string): KpiMeta {
  const exact = KPI_DISPLAY_META[kpiCode]
  if (exact) return exact
  const fallback = kpiCode
    .replace(/_/g, ' ')
    .replace(/\b\w/g, (c) => c.toUpperCase())
  return { label: fallback, description: '', format: 'decimal', order: 999 }
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
      if (den === 0) return 'No guests in base cohort'
      const retained = num ?? 0
      return `Retained ${wholeNumberFormatter.format(
        Math.round(retained),
      )} of ${wholeNumberFormatter.format(Math.round(den))}`
    }
    case 'decimal': {
      if (num == null && den == null) return null
      if (den === 0 || den == null) return 'No guests in window'
      return `${wholeNumberFormatter.format(
        Math.round(num ?? 0),
      )} visits across ${wholeNumberFormatter.format(
        Math.round(den),
      )} guests`
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

/** Resolved drilldown column labels (always concrete strings). */
export type KpiDrilldownColumns = {
  primary: string
  secondary: string
  metric1: string
  metric2: string
  /** Which column holds the guest name (drives title-casing + header). */
  guestNameColumn: 'primary' | null
  /** True when the generic drilldown should drop the secondary column. */
  hideSecondary: boolean
}

const DEFAULT_DRILLDOWN_COLUMNS = {
  primary: 'Primary',
  secondary: 'Secondary',
  metric1: 'Metric 1',
  metric2: 'Metric 2',
} as const

/** Shared column title for any guest-identity column across the drilldowns. */
const GUEST_NAME_HEADER = 'Guest Name'

/**
 * Resolve the drilldown table headers for a KPI. Per-KPI overrides
 * win where defined; missing fields fall back to the generic column
 * names so an unmapped or partially-mapped KPI still renders cleanly.
 *
 * When `guestNameColumn` is set, the matching column's header
 * defaults to the shared "Guest Name" title unless the KPI supplies
 * an explicit override.
 */
export function drilldownColumnsFor(kpiCode: string): KpiDrilldownColumns {
  const overrides = metaFor(kpiCode).drilldown ?? {}
  const guestNameColumn = overrides.guestNameColumn ?? null
  const primary =
    overrides.primary ??
    (guestNameColumn === 'primary'
      ? GUEST_NAME_HEADER
      : DEFAULT_DRILLDOWN_COLUMNS.primary)
  const secondary = overrides.secondary ?? DEFAULT_DRILLDOWN_COLUMNS.secondary
  return {
    primary,
    secondary,
    metric1: overrides.metric1 ?? DEFAULT_DRILLDOWN_COLUMNS.metric1,
    metric2: overrides.metric2 ?? DEFAULT_DRILLDOWN_COLUMNS.metric2,
    guestNameColumn,
    hideSecondary: overrides.hideSecondary === true,
  }
}

/**
 * Title-case a guest name for display in the drilldown tables. Handles
 * simple whitespace-separated names and common intra-word boundaries
 * (`-`, `'`) so both "janet russel" → "Janet Russel" and "o'brien" →
 * "O'Brien" come out right. Passes through the em-dash placeholder the
 * backend uses for missing identities unchanged. Returns `null` for
 * nullish/empty inputs so callers can render their own "—" fallback.
 */
export function titleCaseGuestName(
  v: string | null | undefined,
): string | null {
  if (v == null) return null
  const t = v.trim()
  if (t === '') return null
  if (t === '—') return t
  return t.toLowerCase().replace(/\b([a-z])/g, (m) => m.toUpperCase())
}

/**
 * Raw numeric renderer for diagnostic panels and tables. Preserves the
 * full precision returned by the RPC (`numeric(18, 4)`), adds
 * thousands separators, and collapses nullish inputs to the standard
 * em-dash used elsewhere in the app. Falls back to the raw string
 * when the value is not finite (e.g. a JSON-encoded bigint).
 */
export function formatRawNumber(v: number | string | null | undefined): string {
  if (v == null || v === '') return '—'
  const n = typeof v === 'number' ? v : Number(v)
  if (!Number.isFinite(n)) return String(v)
  return n.toLocaleString(undefined, { maximumFractionDigits: 4 })
}
