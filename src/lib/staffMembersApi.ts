/**
 * Staff master CRUD (elevated users only; RLS on `staff_members`).
 */
import type {
  StaffMemberRow,
  StaffRoleAssignmentRow,
} from '@/features/admin/types/staffConfiguration'
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
  primary_location_id: string | null
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
  contractor_email: string | null
  /**
   * Contractor invoice name is no longer collected via Staff Admin — invoice
   * person name is taken from `staff_members.full_name`. Column intentionally
   * left in the DB for now; this form simply does not write to it.
   */
  contractor_invoice_code: string | null
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
      primary_location_id: payload.primary_location_id,
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
      contractor_email: emptyToNull(payload.contractor_email),
      contractor_invoice_code: emptyToNull(payload.contractor_invoice_code),
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

/**
 * Args for the effective-dated role/pay write path. Mirrors
 * `public.apply_staff_role_assignment(...)` (migration 20260828120300).
 * The RPC closes the currently-open assignment and inserts a new one (or
 * updates in-place when one already starts on `effectiveStartDate`), and
 * syncs the latest values onto `staff_members`.
 */
export type ApplyStaffRoleAssignmentArgs = {
  staffMemberId: string
  /** YYYY-MM-DD. */
  effectiveStartDate: string
  primaryRole: string | null
  secondaryRoles: string | null
  employmentType: string | null
  remunerationPlan: string | null
  fte: number | null
  primaryLocationId: string | null
  reason: string | null
}

/** Envelope returned by the RPC. Only the fields the UI uses are typed. */
export type ApplyStaffRoleAssignmentResult = {
  success: boolean
  action: 'updated_existing' | 'inserted_new'
  assignment_id: string
  previous_open_id: string | null
  previous_open_end_date: string | null
  staff_member_id: string
  effective_start_date: string
  synced_staff_members: boolean
  message: string
}

export async function applyStaffRoleAssignment(
  args: ApplyStaffRoleAssignmentArgs,
): Promise<ApplyStaffRoleAssignmentResult> {
  const { data, error } = await requireSupabaseClient().rpc(
    'apply_staff_role_assignment',
    {
      p_staff_member_id: args.staffMemberId,
      p_effective_start_date: args.effectiveStartDate,
      p_primary_role: emptyToNull(args.primaryRole),
      p_secondary_roles: emptyToNull(args.secondaryRoles),
      p_employment_type: emptyToNull(args.employmentType),
      p_remuneration_plan: emptyToNull(args.remunerationPlan),
      p_fte: args.fte,
      p_primary_location_id:
        args.primaryLocationId && args.primaryLocationId.trim() !== ''
          ? args.primaryLocationId
          : null,
      p_reason: emptyToNull(args.reason),
    },
  )
  if (error) throw toError('apply_staff_role_assignment', error)
  return data as ApplyStaffRoleAssignmentResult
}

/**
 * Returns the effective-dated role/pay history for a staff member,
 * most-recent-first, with the primary location name joined for display.
 * Calls `public.list_staff_role_assignments(p_staff_member_id)`.
 */
export async function fetchStaffRoleAssignments(
  staffMemberId: string,
): Promise<StaffRoleAssignmentRow[]> {
  const id = String(staffMemberId ?? '').trim()
  if (id === '') return []
  const { data, error } = await requireSupabaseClient().rpc(
    'list_staff_role_assignments',
    { p_staff_member_id: id },
  )
  if (error) throw toError('list_staff_role_assignments', error)
  return asRows(data as StaffRoleAssignmentRow[])
}

/**
 * Args for the safe undo write path. Mirrors
 * `public.undo_latest_staff_role_assignment(...)` (migration 20260828120400).
 * Deletes the supplied CURRENT OPEN assignment row, reopens the
 * immediately previous assignment (sets effective_end_date = null), and
 * syncs staff_members back to that reopened row.
 *
 * The RPC rejects when the assignment is not the open row, does not
 * belong to the staff member, or there is no previous row to reopen.
 */
export type UndoLatestStaffRoleAssignmentArgs = {
  staffMemberId: string
  assignmentId: string
  reason: string | null
}

export type UndoLatestStaffRoleAssignmentResult = {
  success: boolean
  deleted_assignment_id: string
  reopened_assignment_id: string
  reopened_effective_start_date: string
  staff_member_id: string
  reason: string | null
  message: string
}

export async function undoLatestStaffRoleAssignment(
  args: UndoLatestStaffRoleAssignmentArgs,
): Promise<UndoLatestStaffRoleAssignmentResult> {
  const { data, error } = await requireSupabaseClient().rpc(
    'undo_latest_staff_role_assignment',
    {
      p_staff_member_id: args.staffMemberId,
      p_assignment_id: args.assignmentId,
      p_reason: emptyToNull(args.reason),
    },
  )
  if (error) throw toError('undo_latest_staff_role_assignment', error)
  return data as UndoLatestStaffRoleAssignmentResult
}

function emptyToNull(s: string | null): string | null {
  if (s == null) return null
  const t = s.trim()
  return t === '' ? null : t
}
