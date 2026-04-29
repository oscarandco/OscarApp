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
  created_at: string
  updated_at: string
}
