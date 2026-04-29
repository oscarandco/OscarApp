import type { AdminPayrollLineRow } from '@/features/admin/types'
import { badgeFromPaidPrimaryLocation } from '@/lib/locationNavBadge'

/** Categories grouped under “Services” in dashboard Table A (non product-type retail/prof splits). */
const TABLE_A_SERVICE_CATEGORIES = new Set<string>([
  'service',
  'toner_with_other_service',
  'extensions_service',
  'extensions_product',
])

const TABLE_A_PROF = 'professional_product'
const TABLE_A_RETAIL = 'retail_product'

const COMM_PRODUCTS_LABEL = 'Comm - Products'
const COMM_SERVICES_LABEL = 'Comm - Services'

function num(v: unknown): number {
  if (v == null || v === '') return 0
  const n = typeof v === 'number' ? v : Number(v)
  return Number.isFinite(n) ? n : 0
}

/** Grouping / display label: full name when present, else display name. */
function staffKey(row: AdminPayrollLineRow): string {
  const full = row.derived_staff_paid_full_name
  if (full != null && String(full).trim() !== '') return String(full).trim()
  const display = row.derived_staff_paid_display_name
  if (display != null && String(display).trim() !== '') return String(display).trim()
  return '—'
}

function staffPaidIdFromRow(row: AdminPayrollLineRow): string | null {
  const id = String(row.derived_staff_paid_id ?? '').trim()
  return id !== '' ? id : null
}

type StaffBucket = {
  staffPaidId: string | null
  paidPrimaryCode: string | null
  paidPrimaryName: string | null
}

function ensureStaffId(bucket: StaffBucket, row: AdminPayrollLineRow) {
  if (bucket.staffPaidId != null) return
  const id = staffPaidIdFromRow(row)
  if (id != null) bucket.staffPaidId = id
}

function mergePaidPrimaryLocation(bucket: StaffBucket, row: AdminPayrollLineRow) {
  const code = row.derived_staff_paid_primary_location_code
  if (
    bucket.paidPrimaryCode == null &&
    code != null &&
    String(code).trim() !== ''
  ) {
    bucket.paidPrimaryCode = String(code).trim()
  }
  const name = row.derived_staff_paid_primary_location_name
  if (
    bucket.paidPrimaryName == null &&
    name != null &&
    String(name).trim() !== ''
  ) {
    bucket.paidPrimaryName = String(name).trim()
  }
}

function normLoc(name: string | null | undefined): string {
  return String(name ?? '')
    .trim()
    .toLowerCase()
}

export function isOrewaLocation(locationName: string | null | undefined): boolean {
  return normLoc(locationName).includes('orewa')
}

export function isTakapunaLocation(locationName: string | null | undefined): boolean {
  return normLoc(locationName).includes('takapuna')
}

export type WeekSummaryCards = {
  totalActualCommissionExGst: number
  totalSalesExGst: number
  orewaSalesExGst: number
  takapunaSalesExGst: number
}

export function aggregateWeekSummaryCards(lines: AdminPayrollLineRow[]): WeekSummaryCards {
  let totalActualCommissionExGst = 0
  let totalSalesExGst = 0
  let orewaSalesExGst = 0
  let takapunaSalesExGst = 0

  for (const row of lines) {
    totalActualCommissionExGst += num(row.actual_commission_amt_ex_gst)
    const sale = num(row.price_ex_gst)
    totalSalesExGst += sale
    const loc = row.location_name
    if (isOrewaLocation(loc)) orewaSalesExGst += sale
    if (isTakapunaLocation(loc)) takapunaSalesExGst += sale
  }

  return {
    totalActualCommissionExGst,
    totalSalesExGst,
    orewaSalesExGst,
    takapunaSalesExGst,
  }
}

export type TableARow = {
  staffPaid: string
  /** First non-null `derived_staff_paid_id` seen for this staff grouping; used for line preview filter. */
  staffPaidId: string | null
  /** O / T from paid staff primary location when set; else null. */
  locationBadge: 'O' | 'T' | null
  profProd: number
  retailProd: number
  services: number
  total: number
}

/** Table A: by commission_category_final — prof / retail / services bucket. */
export function aggregateTableAByStaff(lines: AdminPayrollLineRow[]): TableARow[] {
  const map = new Map<
    string,
    {
      profProd: number
      retailProd: number
      services: number
      staffPaidId: string | null
      paidPrimaryCode: string | null
      paidPrimaryName: string | null
    }
  >()

  for (const row of lines) {
    const key = staffKey(row)
    const amt = num(row.actual_commission_amt_ex_gst)
    const cat = String(row.commission_category_final ?? '').trim().toLowerCase()

    if (!map.has(key)) {
      map.set(key, {
        profProd: 0,
        retailProd: 0,
        services: 0,
        staffPaidId: null,
        paidPrimaryCode: null,
        paidPrimaryName: null,
      })
    }
    const b = map.get(key)!
    ensureStaffId(b, row)
    mergePaidPrimaryLocation(b, row)

    if (cat === TABLE_A_PROF) b.profProd += amt
    else if (cat === TABLE_A_RETAIL) b.retailProd += amt
    else if (TABLE_A_SERVICE_CATEGORIES.has(cat)) b.services += amt
  }

  const rows: TableARow[] = [...map.entries()].map(([staffPaid, v]) => ({
    staffPaid,
    staffPaidId: v.staffPaidId,
    locationBadge: badgeFromPaidPrimaryLocation(
      v.paidPrimaryCode,
      v.paidPrimaryName,
    ),
    profProd: v.profProd,
    retailProd: v.retailProd,
    services: v.services,
    total: v.profProd + v.retailProd + v.services,
  }))

  rows.sort((a, b) => a.staffPaid.localeCompare(b.staffPaid, undefined, { sensitivity: 'base' }))
  return rows
}

export type TableBRow = {
  staffPaid: string
  staffPaidId: string | null
  locationBadge: 'O' | 'T' | null
  commProducts: number
  commServices: number
  total: number
}

/** Table B: by commission_product_service (Comm - Products vs Comm - Services). */
export function aggregateTableBByStaff(lines: AdminPayrollLineRow[]): TableBRow[] {
  const map = new Map<
    string,
    {
      commProducts: number
      commServices: number
      staffPaidId: string | null
      paidPrimaryCode: string | null
      paidPrimaryName: string | null
    }
  >()

  for (const row of lines) {
    const key = staffKey(row)
    const amt = num(row.actual_commission_amt_ex_gst)
    const cps = String(row.commission_product_service ?? '').trim()

    if (!map.has(key)) {
      map.set(key, {
        commProducts: 0,
        commServices: 0,
        staffPaidId: null,
        paidPrimaryCode: null,
        paidPrimaryName: null,
      })
    }
    const b = map.get(key)!
    ensureStaffId(b, row)
    mergePaidPrimaryLocation(b, row)

    if (cps === COMM_PRODUCTS_LABEL) b.commProducts += amt
    else if (cps === COMM_SERVICES_LABEL) b.commServices += amt
  }

  const rows: TableBRow[] = [...map.entries()].map(([staffPaid, v]) => ({
    staffPaid,
    staffPaidId: v.staffPaidId,
    locationBadge: badgeFromPaidPrimaryLocation(
      v.paidPrimaryCode,
      v.paidPrimaryName,
    ),
    commProducts: v.commProducts,
    commServices: v.commServices,
    total: v.commProducts + v.commServices,
  }))

  rows.sort((a, b) => a.staffPaid.localeCompare(b.staffPaid, undefined, { sensitivity: 'base' }))
  return rows
}

/** Summary card keys: commission & sales = all lines; location cards = that salon only. */
export type DashboardCardFilter = 'commission' | 'sales' | 'orewa' | 'takapuna'

export function filterLinesForDashboardCard(
  lines: AdminPayrollLineRow[],
  filter: DashboardCardFilter | null,
): AdminPayrollLineRow[] {
  if (filter == null || filter === 'commission' || filter === 'sales') {
    return lines
  }
  if (filter === 'orewa') return lines.filter((l) => isOrewaLocation(l.location_name))
  if (filter === 'takapuna') return lines.filter((l) => isTakapunaLocation(l.location_name))
  return lines
}
