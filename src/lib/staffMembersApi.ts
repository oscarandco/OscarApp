/**
 * Staff master CRUD (elevated users only; RLS on `staff_members`).
 */
import type { StaffMemberRow } from '@/features/admin/types/staffConfiguration'
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

export async function fetchStaffMembers(): Promise<StaffMemberRow[]> {
  const { data, error } = await requireSupabaseClient()
    .from('staff_members')
    .select('*')
    .order('full_name')
  if (error) throw toError('staff_members', error)
  return asRows(data as StaffMemberRow[])
}

/** Plan names from `remuneration_plans` for dropdowns (matches `staff_members.remuneration_plan` text). */
export async function fetchRemunerationPlanNames(): Promise<string[]> {
  const { data, error } = await requireSupabaseClient()
    .from('remuneration_plans')
    .select('plan_name')
    .order('plan_name')
  if (error) throw toError('remuneration_plans', error)
  return asRows(data as { plan_name: string }[]).map((r) => r.plan_name)
}

export async function insertStaffMember(args: {
  full_name: string
}): Promise<StaffMemberRow> {
  const supabase = requireSupabaseClient()
  const { data, error } = await supabase
    .from('staff_members')
    .insert({
      full_name: args.full_name.trim(),
      is_active: true,
    })
    .select('*')
    .single()
  if (error) throw toError('staff_members insert', error)
  return data as StaffMemberRow
}

export type StaffMemberUpdatePayload = {
  id: string
  full_name: string
  display_name: string | null
  primary_role: string | null
  secondary_roles: string | null
  remuneration_plan: string | null
  employment_type: string | null
  fte: number | null
  employment_start_date: string | null
  employment_end_date: string | null
  is_active: boolean
  notes: string | null
  contractor_company_name: string | null
  contractor_gst_registered: boolean
  contractor_ird_number: string | null
  contractor_street_address: string | null
  contractor_suburb: string | null
  contractor_city_postcode: string | null
}

export async function updateStaffMember(
  payload: StaffMemberUpdatePayload,
): Promise<void> {
  const { error } = await requireSupabaseClient()
    .from('staff_members')
    .update({
      full_name: payload.full_name.trim(),
      display_name: emptyToNull(payload.display_name),
      primary_role: emptyToNull(payload.primary_role),
      secondary_roles: emptyToNull(payload.secondary_roles),
      remuneration_plan: emptyToNull(payload.remuneration_plan),
      employment_type: emptyToNull(payload.employment_type),
      fte: payload.fte,
      employment_start_date: emptyToNull(payload.employment_start_date),
      employment_end_date: emptyToNull(payload.employment_end_date),
      is_active: payload.is_active,
      notes: emptyToNull(payload.notes),
      contractor_company_name: emptyToNull(payload.contractor_company_name),
      contractor_gst_registered: payload.contractor_gst_registered,
      contractor_ird_number: emptyToNull(payload.contractor_ird_number),
      contractor_street_address: emptyToNull(payload.contractor_street_address),
      contractor_suburb: emptyToNull(payload.contractor_suburb),
      contractor_city_postcode: emptyToNull(payload.contractor_city_postcode),
    })
    .eq('id', payload.id)
  if (error) throw toError('staff_members update', error)
}

/** Removes the staff row and dependent KPI / access rows (elevated callers only; RPC-enforced). */
export async function deleteStaffMember(staffMemberId: string): Promise<void> {
  const { error } = await requireSupabaseClient().rpc('delete_staff_member_admin', {
    p_staff_member_id: staffMemberId,
  })
  if (error) throw toError('delete_staff_member_admin', error)
}

function emptyToNull(s: string | null): string | null {
  if (s == null) return null
  const t = s.trim()
  return t === '' ? null : t
}
