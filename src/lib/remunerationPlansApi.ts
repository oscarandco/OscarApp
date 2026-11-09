/**
 * Remuneration plan CRUD (elevated users only; RLS on `remuneration_*` tables).
 * Staff linkage reads use SECURITY DEFINER RPCs (see migration).
 */
import type {
  RemunerationPlanRateRow,
  RemunerationPlanRow,
  RemunerationPlanWithRates,
  StaffOnPlanRow,
  TheoreticalBenchmarkRow,
} from '@/features/admin/types/remuneration'
import {
  REMUNERATION_COMMISSION_CATEGORIES,
  type RemunerationCommissionCategory,
} from '@/features/admin/types/remuneration'
import { requireSupabaseClient } from '@/lib/supabase'

import type { PostgrestError } from '@supabase/supabase-js'

function toError(op: string, err: PostgrestError): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

function asRows<T>(data: T | T[] | null): T[] {
  if (data == null) return []
  return Array.isArray(data) ? data : [data]
}

export async function fetchRemunerationPlansWithRates(): Promise<
  RemunerationPlanWithRates[]
> {
  const supabase = requireSupabaseClient()
  const { data: plans, error: pe } = await supabase
    .from('remuneration_plans')
    .select('*')
    .order('plan_name')
  if (pe) throw toError('remuneration_plans', pe)
  const planRows = asRows(plans as RemunerationPlanRow[])
  if (planRows.length === 0) return []

  const ids = planRows.map((p) => p.id)
  const { data: rates, error: re } = await supabase
    .from('remuneration_plan_rates')
    .select('*')
    .in('remuneration_plan_id', ids)
  if (re) throw toError('remuneration_plan_rates', re)
  const rateRows = asRows(rates as RemunerationPlanRateRow[])
  const byPlan = new Map<string, RemunerationPlanRateRow[]>()
  for (const r of rateRows) {
    const list = byPlan.get(r.remuneration_plan_id) ?? []
    list.push(r)
    byPlan.set(r.remuneration_plan_id, list)
  }
  return planRows.map((p) => ({
    ...p,
    rates: byPlan.get(p.id) ?? [],
  }))
}

export type PlanStaffCountRow = { plan_id: string; staff_count: number }

export async function fetchRemunerationStaffCounts(): Promise<PlanStaffCountRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'admin_remuneration_staff_counts_by_id',
  )
  if (error) throw toError('admin_remuneration_staff_counts_by_id', error)
  return asRows(data as { plan_id: string; staff_count: number }[]).map((r) => ({
    plan_id: r.plan_id,
    staff_count: Number(r.staff_count),
  }))
}

export async function fetchStaffForRemunerationPlan(
  planId: string,
): Promise<StaffOnPlanRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'admin_staff_for_remuneration_plan_id',
    { p_plan_id: planId },
  )
  if (error) throw toError('admin_staff_for_remuneration_plan_id', error)
  return asRows(data as StaffOnPlanRow[])
}

/** Header and all rates are saved in one database transaction. */
export async function saveRemunerationPlan(args: {
  id: string | null
  plan_name: string
  can_use_assistants: boolean
  conditions_text: string | null
  deduct_service_product_costs: boolean
  rates: Record<RemunerationCommissionCategory, number>
}): Promise<string> {
  const { data, error } = await requireSupabaseClient().rpc('admin_save_remuneration_plan', {
    p_plan_id: args.id,
    p_plan_name: args.plan_name.trim(),
    p_can_use_assistants: args.can_use_assistants,
    p_conditions_text: args.conditions_text,
    p_deduct_service_product_costs: args.deduct_service_product_costs,
    p_rates: args.rates,
  })
  if (error) throw toError('admin_save_remuneration_plan', error)
  return data as string
}

export async function insertRemunerationPlan(args: { planName: string }): Promise<string> {
  return saveRemunerationPlan({
    id: null, plan_name: args.planName, can_use_assistants: false,
    conditions_text: null, deduct_service_product_costs: false,
    rates: Object.fromEntries(REMUNERATION_COMMISSION_CATEGORIES.map((cat) => [cat, 0])) as Record<RemunerationCommissionCategory, number>,
  })
}

export async function duplicateRemunerationPlan(planId: string, planName: string): Promise<string> {
  const { data, error } = await requireSupabaseClient().rpc('admin_duplicate_remuneration_plan', {
    p_plan_id: planId, p_plan_name: planName.trim(),
  })
  if (error) throw toError('admin_duplicate_remuneration_plan', error)
  return data as string
}

export async function setRemunerationPlanActive(planId: string, active: boolean): Promise<void> {
  const { error } = await requireSupabaseClient().rpc('admin_set_remuneration_plan_active', {
    p_plan_id: planId, p_is_active: active,
  })
  if (error) throw toError('admin_set_remuneration_plan_active', error)
}

export async function fetchTheoreticalBenchmarks(): Promise<TheoreticalBenchmarkRow[]> {
  const { data, error } = await requireSupabaseClient().rpc('admin_list_theoretical_benchmarks')
  if (error) throw toError('admin_list_theoretical_benchmarks', error)
  return asRows(data as TheoreticalBenchmarkRow[])
}

export async function setTheoreticalBenchmark(planId: string, effectiveStartDate: string): Promise<void> {
  const { error } = await requireSupabaseClient().rpc('admin_set_theoretical_benchmark', {
    p_plan_id: planId, p_effective_start_date: effectiveStartDate,
  })
  if (error) throw toError('admin_set_theoretical_benchmark', error)
}

/** Database rejects deletion when current staff, history or a benchmark references the plan ID. */
export async function deleteRemunerationPlanIfUnused(planId: string): Promise<void> {
  const { error } = await requireSupabaseClient().rpc(
    'admin_delete_remuneration_plan_if_unused',
    { p_plan_id: planId },
  )
  if (error) throw toError('admin_delete_remuneration_plan_if_unused', error)
}
