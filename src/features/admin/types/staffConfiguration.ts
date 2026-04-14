/** Row shape for `public.staff_members` (Staff Configuration admin). */
export type StaffMemberRow = {
  id: string
  full_name: string
  display_name: string | null
  primary_role: string | null
  secondary_roles: string | null
  remuneration_plan: string | null
  employment_type: string | null
  fte: number | string | null
  employment_start_date: string | null
  employment_end_date: string | null
  is_active: boolean
  first_seen_sale_date: string | null
  last_seen_sale_date: string | null
  notes: string | null
  created_at: string
  updated_at: string
}
