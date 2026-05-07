import { StaffLocationNavBadge } from '@/features/admin/components/StaffLocationNavBadge'
import type { AdminAccessMappingRow } from '@/features/admin/types/accessManagement'
import type { ImportLocationRow } from '@/lib/supabaseRpc'
import { primaryLocationNavBadge } from '@/lib/locationNavBadge'

type Props = {
  row: AdminAccessMappingRow
  /** Map staff_member.id → primary_location_id; omit while loading. */
  primaryLocationByStaffId: Map<string, string | null> | undefined
  locations: ImportLocationRow[] | undefined
}

/**
 * Staff column display for Access Management — same name structure as before,
 * plus compact O/T pills matching {@link StaffLocationNavBadge} / Staff admin nav.
 */
export function AccessManagementStaffCell({
  row,
  primaryLocationByStaffId,
  locations,
}: Props) {
  const sid = row.staff_member_id?.trim()
  const locId =
    sid && primaryLocationByStaffId
      ? (primaryLocationByStaffId.get(sid) ?? null)
      : null
  const letter =
    locations && primaryLocationByStaffId
      ? primaryLocationNavBadge(locId, locations)
      : null

  const primary = row.staff_display_name ?? row.staff_full_name ?? '—'
  const showSecondary =
    Boolean(row.staff_display_name) &&
    Boolean(row.staff_full_name) &&
    row.staff_display_name!.trim() !== row.staff_full_name!.trim()

  return (
    <div className="flex min-w-0 items-center gap-1.5">
      <span className="min-w-0">
        <span className="font-medium">{primary}</span>
        {showSecondary ? (
          <span className="ml-1 text-slate-500">({row.staff_full_name})</span>
        ) : null}
      </span>
      {letter ? <StaffLocationNavBadge letter={letter} /> : null}
    </div>
  )
}
