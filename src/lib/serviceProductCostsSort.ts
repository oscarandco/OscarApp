import type { ServiceProductCost } from '@/lib/serviceProductCostsApi'
import { compareScalarsForSort, stableSorted, type ColumnSortState } from './tableSort.ts'

export type ServiceCostDraft = { amount: string; effectiveFrom: string }
export type ServiceCostSortKey =
  | 'service_name' | 'classification_labels' | 'unit_cost_ex_gst'
  | 'effective_from' | 'seen_in_sales' | 'last_sale_date' | 'archived_at'
  | 'draft_unit_cost' | 'draft_effective_from'

export function sortServiceProductCosts(
  rows: ServiceProductCost[],
  sort: ColumnSortState,
  drafts: Record<string, ServiceCostDraft>,
  asOf: string,
): ServiceProductCost[] {
  if (!sort) return rows
  const key = sort.key
  const kind = ['unit_cost_ex_gst', 'draft_unit_cost', 'seen_in_sales'].includes(key)
    ? 'number'
    : ['effective_from', 'last_sale_date', 'archived_at', 'draft_effective_from'].includes(key)
      ? 'date' : 'text'
  function value(row: ServiceProductCost) {
    switch (key) {
      case 'service_name': return row.service_name
      case 'classification_labels': return row.classification_labels?.join(', ') || null
      case 'unit_cost_ex_gst': return row.unit_cost_ex_gst
      case 'effective_from': return row.effective_from
      case 'seen_in_sales': return row.seen_in_sales
      case 'last_sale_date': return row.last_sale_date
      case 'archived_at': return row.archived_at
      case 'draft_unit_cost': return drafts[row.service_id]?.amount ?? null
      case 'draft_effective_from': return drafts[row.service_id]?.effectiveFrom ?? asOf
      default: return null
    }
  }
  return stableSorted(rows, (a, b) => compareScalarsForSort(value(a), value(b), kind, sort.dir))
}
