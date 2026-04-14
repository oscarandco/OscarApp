/**
 * Remuneration plan CRUD (elevated users only; RLS on `remuneration_*` tables).
 * Staff linkage reads use SECURITY DEFINER RPCs (see migration).
 */
import type {
  RemunerationPlanRateRow,
  RemunerationPlanRow,
  RemunerationPlanWithRates,
  StaffOnPlanRow,
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

export type PlanStaffCountRow = { plan_key: string; staff_count: number }

export async function fetchRemunerationStaffCounts(): Promise<PlanStaffCountRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'admin_remuneration_staff_counts',
  )
  if (error) throw toError('admin_remuneration_staff_counts', error)
  return asRows(data as { plan_key: string; staff_count: number }[]).map((r) => ({
    plan_key: r.plan_key,
    staff_count: Number(r.staff_count),
  }))
}

export async function fetchStaffForRemunerationPlan(
  planName: string,
): Promise<StaffOnPlanRow[]> {
  const { data, error } = await requireSupabaseClient().rpc(
    'admin_staff_for_remuneration_plan',
    { p_plan_name: planName },
  )
  if (error) throw toError('admin_staff_for_remuneration_plan', error)
  return asRows(data as StaffOnPlanRow[])
}

export async function insertRemunerationPlan(args: {
  planName: string
}): Promise<RemunerationPlanWithRates> {
  const supabase = requireSupabaseClient()
  const { data: plan, error: ie } = await supabase
    .from('remuneration_plans')
    .insert({
      plan_name: args.planName.trim(),
      can_use_assistants: false,
      is_active: true,
      conditions_text: null,
      staff_on_this_plan_text: null,
    })
    .select('*')
    .single()
  if (ie) throw toError('remuneration_plans insert', ie)
  const p = plan as RemunerationPlanRow
  const rateInserts = REMUNERATION_COMMISSION_CATEGORIES.map((commission_category) => ({
    remuneration_plan_id: p.id,
    commission_category,
    rate: 0,
  }))
  const { error: re } = await supabase.from('remuneration_plan_rates').insert(rateInserts)
  if (re) throw toError('remuneration_plan_rates insert', re)
  const { data: rateRows, error: rsel } = await supabase
    .from('remuneration_plan_rates')
    .select('*')
    .eq('remuneration_plan_id', p.id)
  if (rsel) throw toError('remuneration_plan_rates select', rsel)
  return { ...p, rates: asRows(rateRows as RemunerationPlanRateRow[]) }
}

export async function updateRemunerationPlanHeader(args: {
  id: string
  plan_name: string
  can_use_assistants: boolean | null
  conditions_text: string | null
}): Promise<void> {
  const { error } = await requireSupabaseClient()
    .from('remuneration_plans')
    .update({
      plan_name: args.plan_name.trim(),
      can_use_assistants: args.can_use_assistants,
      conditions_text: args.conditions_text,
    })
    .eq('id', args.id)
  if (error) throw toError('remuneration_plans update', error)
}

/** Persist category rates (0–1 fractions). Upserts all categories for the plan. */
export async function upsertRemunerationPlanRates(args: {
  remuneration_plan_id: string
  rates: Partial<Record<RemunerationCommissionCategory, number>>
}): Promise<void> {
  const supabase = requireSupabaseClient()
  const rows = REMUNERATION_COMMISSION_CATEGORIES.map((commission_category) => {
    const v = args.rates[commission_category]
    const rate =
      v == null || Number.isNaN(v) ? 0 : Math.min(1, Math.max(0, v))
    return {
      remuneration_plan_id: args.remuneration_plan_id,
      commission_category,
      rate,
    }
  })
  const { error } = await supabase.from('remuneration_plan_rates').upsert(rows, {
    onConflict: 'remuneration_plan_id,commission_category',
  })
  if (error) throw toError('remuneration_plan_rates upsert', error)
}

/** Deletes plan and cascaded rates only when no staff reference this plan name. */
export async function deleteRemunerationPlanIfUnused(planId: string): Promise<void> {
  const { error } = await requireSupabaseClient().rpc(
    'admin_delete_remuneration_plan_if_unused',
    { p_plan_id: planId },
  )
  if (error) throw toError('admin_delete_remuneration_plan_if_unused', error)
}
