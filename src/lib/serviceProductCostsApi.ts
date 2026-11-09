import { requireSupabaseClient } from '@/lib/supabase'

export type ServiceProductCost = {
  service_id: string
  service_name: string
  is_active: boolean
  archived_at?: string | null
  unit_cost_ex_gst: number | string | null
  effective_from: string | null
  effective_to: string | null
  seen_in_sales: boolean
  first_sale_date: string | null
  last_sale_date: string | null
  source_product_ids?: string[] | null
  location_names?: string[] | null
  classification_labels?: string[] | null
}

export type ServiceProductCostVersion = {
  id: string
  service_id: string
  unit_cost_ex_gst: number | string
  effective_from: string
  effective_to: string | null
}

export type ServiceCostInput = {
  service_id: string
  unit_cost_ex_gst: number
  effective_from: string
}

export type PayrollCostIssue = {
  issue_key: string
  service_id: string | null
  service_name: string
  first_sale_date: string
  last_sale_date: string
  affected_units: number | string | null
  reason: string
  suggested_effective_from: string
}

export type PayrollCostSales = {
  total_sales_ex_gst: number | string | null
  orewa_sales_ex_gst: number | string | null
  takapuna_sales_ex_gst: number | string | null
}

async function rpc<T>(name: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await requireSupabaseClient().rpc(name, args)
  if (error) throw new Error(error.message || `Could not complete ${name}`)
  return data as T
}

export function getServiceProductCosts(asOf: string) {
  return rpc<ServiceProductCost[]>('get_service_product_costs', { p_as_of: asOf })
}

export function getServiceProductCostHistory(serviceId: string) {
  return rpc<ServiceProductCostVersion[]>('get_service_product_cost_history', { p_service_id: serviceId })
}

export function saveServiceProductCosts(costs: ServiceCostInput[]) {
  return rpc<unknown>('save_service_product_costs', { p_costs: costs })
}

export function createServiceProductCostService(name: string) {
  return rpc<string>('create_service_product_cost_service', { p_service_name: name })
}

export function setServiceProductCostServiceActive(serviceId: string, active: boolean) {
  return rpc<unknown>('set_service_product_cost_service_active', { p_service_id: serviceId, p_is_active: active })
}

export function getPayrollCostReadiness(week: string) {
  return rpc<PayrollCostIssue[]>('get_payroll_cost_readiness', { p_pay_week_start: week })
}

export function getPayrollCostWeeks() {
  return rpc<Array<{ pay_week_start: string }>>('get_payroll_cost_weeks')
}

export async function getPayrollCostSales(week: string) {
  const result = await rpc<PayrollCostSales[]>('get_payroll_cost_sales', { p_pay_week_start: week })
  return result[0] ?? null
}

/** Validate entered money without turning a blank field into an explicit zero. */
export function parseServiceCost(value: string): number {
  if (!/^\d+(?:\.\d{1,2})?$/.test(value.trim())) {
    throw new Error('Enter a product cost of zero or more, with up to two decimal places.')
  }
  const amount = Number(value)
  if (!Number.isFinite(amount)) throw new Error('Enter a valid product cost.')
  return amount
}

export function localDateInputValue() {
  const now = new Date()
  return `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`
}
