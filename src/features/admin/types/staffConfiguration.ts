/** Row shape for `public.staff_members` (Staff Configuration admin). */
export type StaffMemberRow = {
  id: string
  full_name: string
  display_name: string | null
  primary_role: string | null
  secondary_roles: string | null
  remuneration_plan: string | null
  employment_type: string | null
  /** FK to `public.locations.id` when set. Omitted until migration applied. */
  primary_location_id?: string | null
  fte: number | string | null
  employment_start_date: string | null
  employment_end_date: string | null
  is_active: boolean
  first_seen_sale_date: string | null
  last_seen_sale_date: string | null
  notes: string | null
  contractor_company_name: string | null
  contractor_gst_registered: boolean | null
  contractor_ird_number: string | null
  contractor_street_address: string | null
  contractor_suburb: string | null
  contractor_city_postcode: string | null
  /** Contractor invoicing fields (see migration 20260825120000_staff_members_invoice_columns). */
  contractor_email: string | null
  contractor_invoice_name: string | null
  contractor_invoice_code: string | null
  created_at: string
  updated_at: string
}

/**
 * Row shape for `public.staff_role_assignments` (effective-dated role / pay
 * history; see migrations 20260828120000 + 20260828120300). Returned via
 * `list_staff_role_assignments(p_staff_member_id)` which joins
 * `primary_location_name` for display.
 */
export type StaffRoleAssignmentRow = {
  id: string
  staff_member_id: string
  /** Inclusive start date (YYYY-MM-DD). */
  effective_start_date: string
  /** Inclusive end date (YYYY-MM-DD); `null` = open / currently active. */
  effective_end_date: string | null
  primary_role: string | null
  secondary_roles: string | null
  employment_type: string | null
  remuneration_plan: string | null
  fte: number | string | null
  primary_location_id: string | null
  primary_location_name: string | null
  reason: string | null
  created_at: string
  created_by: string | null
  updated_at: string
  updated_by: string | null
}

