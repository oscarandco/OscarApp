import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'

import { ConfirmDialog } from '@/components/feedback/ConfirmDialog'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import {
  ApplyRoleAssignmentModal,
  type RoleAssignmentChange,
} from '@/features/admin/components/ApplyRoleAssignmentModal'
import { StaffLocationNavBadge } from '@/features/admin/components/StaffLocationNavBadge'
import { useStaffConfiguration } from '@/features/admin/hooks/useStaffConfiguration'
import { useStaffRoleAssignments } from '@/features/admin/hooks/useStaffRoleAssignments'
import type {
  StaffMemberRow,
  StaffRoleAssignmentRow,
} from '@/features/admin/types/staffConfiguration'
import {
  applyStaffRoleAssignment,
  deleteStaffMember,
  insertStaffMember,
  undoLatestStaffRoleAssignment,
  updateStaffMember,
  type StaffMemberUpdatePayload,
} from '@/lib/staffMembersApi'
import { queryErrorDetail } from '@/lib/queryError'
import { primaryLocationNavBadge } from '@/lib/locationNavBadge'
import { formatShortDate } from '@/lib/formatters'
import type { ImportLocationRow, StaffSalesImportMetadataRow } from '@/lib/supabaseRpc'

type StatusFilter = 'all' | 'active' | 'inactive'

type EmploymentKind = 'Employee' | 'Contractor'

/** Form state; maps to `StaffMemberUpdatePayload` on save. `fte` is kept as a string for input-friendly editing (parsed to number|null on save). */
type StaffFormDraft = {
  id: string
  full_name: string
  display_name: string
  primary_role: string
  secondary_roles: string
  remuneration_plan: string
  employment_type: EmploymentKind
  /** Location id (`public.locations.id`); empty string = none. */
  primary_location_id: string
  fte: string
  employment_start_date: string
  employment_end_date: string
  is_active: boolean
  notes: string
  contractor_company_name: string
  contractor_gst_registered: boolean
  contractor_ird_number: string
  contractor_street_address: string
  contractor_suburb: string
  contractor_city_postcode: string
  contractor_email: string
  contractor_invoice_code: string
}

/**
 * Form keys that are sale-date effective. Changes to these go through the
 * `apply_staff_role_assignment` RPC (which closes the current open
 * assignment, inserts a new one, and syncs `staff_members`). Everything
 * NOT in this set is treated as "current snapshot" data and saved via the
 * existing `updateStaffMember` flow.
 */
const ROLE_PAY_KEYS = [
  'primary_role',
  'secondary_roles',
  'remuneration_plan',
  'employment_type',
  'primary_location_id',
  'fte',
] as const satisfies ReadonlyArray<keyof StaffFormDraft>

type RolePayKey = (typeof ROLE_PAY_KEYS)[number]

const ROLE_PAY_LABELS: Record<RolePayKey, string> = {
  primary_role: 'Primary role',
  secondary_roles: 'Secondary roles',
  remuneration_plan: 'Remuneration plan',
  employment_type: 'Employment type',
  primary_location_id: 'Primary location',
  fte: 'FTE',
}

function normalizeEmploymentKind(raw: string | null | undefined): EmploymentKind {
  const s = (raw ?? '').trim().toLowerCase()
  return s === 'contractor' ? 'Contractor' : 'Employee'
}

function isoDateToInput(iso: string | null | undefined): string {
  if (!iso) return ''
  return iso.slice(0, 10)
}

/** One line for Import metadata panel: date · locations, or em dash when no sales. */
function formatLiveSaleSeenLine(
  meta: StaffSalesImportMetadataRow | undefined,
  kind: 'first' | 'last',
): string {
  const date =
    kind === 'first' ? meta?.first_seen_sale_date : meta?.last_seen_sale_date
  const locs =
    kind === 'first'
      ? meta?.first_seen_sale_location_names
      : meta?.last_seen_sale_location_names
  if (!date) return '—'
  const d = isoDateToInput(date)
  const locPart = locs && locs.trim() !== '' ? locs : '—'
  return `${d} · ${locPart}`
}

/** Left-nav bucket from `primary_role` only (no backend). */
function staffNavBucket(row: StaffMemberRow): 'stylists' | 'assistants' | 'other' {
  const role = (row.primary_role ?? '').trim().toLowerCase()
  if (role === 'assistant') return 'assistants'
  if (
    role.includes('stylist') ||
    role.includes('colourist') ||
    role.includes('colorist')
  ) {
    return 'stylists'
  }
  return 'other'
}

function sortKeyForNav(s: StaffMemberRow): string {
  const d = (s.display_name ?? '').trim()
  const f = (s.full_name ?? '').trim()
  const key = d !== '' ? d : f
  return key.toLowerCase()
}

function compareStaffNav(a: StaffMemberRow, b: StaffMemberRow): number {
  return sortKeyForNav(a).localeCompare(sortKeyForNav(b), undefined, { sensitivity: 'base' })
}

function StaffNavRow({
  member: s,
  active,
  onSelect,
  locations,
}: {
  member: StaffMemberRow
  active: boolean
  onSelect: (id: string) => void
  locations: ImportLocationRow[]
}) {
  const disp = s.display_name?.trim() ?? ''
  const full = (s.full_name ?? '').trim()
  const showSecondary =
    disp !== '' && full !== '' && disp.toLowerCase() !== full.toLowerCase()
  const primary = disp === '' ? full : disp
  const locBadge = primaryLocationNavBadge(s.primary_location_id, locations)
  return (
    <li>
      <button
        type="button"
        onClick={() => onSelect(s.id)}
        className={`flex w-full items-center justify-between gap-2 rounded-lg border px-3 py-2.5 text-left text-sm transition ${
          active
            ? 'border-violet-300 bg-violet-50 text-violet-950'
            : 'border-transparent bg-slate-50/80 text-slate-800 hover:border-slate-200 hover:bg-white'
        }`}
      >
        <span className="flex min-w-0 flex-1 items-center gap-1.5 text-left">
          <StaffLocationNavBadge letter={locBadge} />
          <span className="min-w-0 flex-1 truncate">
            <span className="font-medium text-slate-900">{primary}</span>
            {showSecondary ? (
              <span className="text-xs font-normal text-slate-500">
                {' '}
                ({full})
              </span>
            ) : null}
          </span>
        </span>
        <span
          className={`shrink-0 text-xs font-medium ${
            s.is_active ? 'text-emerald-700' : 'text-slate-400'
          }`}
        >
          {s.is_active ? 'Active' : 'Inactive'}
        </span>
      </button>
    </li>
  )
}

function draftFromRow(row: StaffMemberRow): StaffFormDraft {
  return {
    id: row.id,
    full_name: row.full_name,
    display_name: row.display_name ?? '',
    primary_role: row.primary_role ?? '',
    secondary_roles: row.secondary_roles ?? '',
    remuneration_plan: row.remuneration_plan ?? '',
    employment_type: normalizeEmploymentKind(row.employment_type),
    primary_location_id: row.primary_location_id ?? '',
    fte: row.fte == null ? '' : String(row.fte),
    employment_start_date: isoDateToInput(row.employment_start_date),
    employment_end_date: isoDateToInput(row.employment_end_date),
    is_active: row.is_active,
    notes: row.notes ?? '',
    contractor_company_name: row.contractor_company_name ?? '',
    contractor_gst_registered: row.contractor_gst_registered === true,
    contractor_ird_number: row.contractor_ird_number ?? '',
    contractor_street_address: row.contractor_street_address ?? '',
    contractor_suburb: row.contractor_suburb ?? '',
    contractor_city_postcode: row.contractor_city_postcode ?? '',
    contractor_email: row.contractor_email ?? '',
    contractor_invoice_code: row.contractor_invoice_code ?? '',
  }
}

export function StaffConfigurationPage() {
  const queryClient = useQueryClient()
  const { data, isLoading, isError, error, refetch } = useStaffConfiguration()

  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('active')
  const [employmentTypeFilter, setEmploymentTypeFilter] = useState<
    'all' | EmploymentKind
  >('all')
  const [remunerationPlanFilter, setRemunerationPlanFilter] = useState('')
  const [primaryRoleFilter, setPrimaryRoleFilter] = useState('')
  const [draft, setDraft] = useState<StaffFormDraft | null>(null)
  const [confirmDeleteStaff, setConfirmDeleteStaff] = useState<{
    id: string
    label: string
  } | null>(null)

  const staff = data?.staff ?? []
  const planNames = data?.planNames ?? []
  const locations = data?.locations ?? []

  const salesImportMetaByStaffId = useMemo(() => {
    const m = new Map<string, StaffSalesImportMetadataRow>()
    for (const r of data?.salesImportMetadata ?? []) {
      m.set(r.staff_member_id, r)
    }
    return m
  }, [data?.salesImportMetadata])

  const primaryRoleFilterOptions = useMemo(() => {
    const set = new Set<string>()
    for (const s of staff) {
      const r = (s.primary_role ?? '').trim()
      if (r) set.add(r)
    }
    return [...set].sort((a, b) => a.localeCompare(b, undefined, { sensitivity: 'base' }))
  }, [staff])

  const remunerationFilterOptions = useMemo(() => {
    const set = new Set(planNames)
    for (const s of staff) {
      const p = (s.remuneration_plan ?? '').trim()
      if (p) set.add(p)
    }
    return [...set].sort((a, b) => a.localeCompare(b))
  }, [staff, planNames])

  const filteredStaff = useMemo(() => {
    const q = search.trim().toLowerCase()
    return staff.filter((s) => {
      if (statusFilter === 'active' && !s.is_active) return false
      if (statusFilter === 'inactive' && s.is_active) return false
      if (employmentTypeFilter !== 'all') {
        if (normalizeEmploymentKind(s.employment_type) !== employmentTypeFilter) {
          return false
        }
      }
      if (remunerationPlanFilter !== '') {
        const plan = (s.remuneration_plan ?? '').trim()
        if (remunerationPlanFilter === '__none__') {
          if (plan !== '') return false
        } else if (plan !== remunerationPlanFilter) {
          return false
        }
      }
      if (primaryRoleFilter !== '') {
        if ((s.primary_role ?? '').trim() !== primaryRoleFilter) return false
      }
      if (!q) return true
      const hay =
        `${s.full_name} ${s.display_name ?? ''} ${s.primary_role ?? ''} ${s.secondary_roles ?? ''}`.toLowerCase()
      return hay.includes(q)
    })
  }, [
    staff,
    search,
    statusFilter,
    employmentTypeFilter,
    remunerationPlanFilter,
    primaryRoleFilter,
  ])

  const staffNavGroups = useMemo(() => {
    const stylists: StaffMemberRow[] = []
    const assistants: StaffMemberRow[] = []
    const other: StaffMemberRow[] = []
    for (const s of filteredStaff) {
      const b = staffNavBucket(s)
      if (b === 'stylists') stylists.push(s)
      else if (b === 'assistants') assistants.push(s)
      else other.push(s)
    }
    stylists.sort(compareStaffNav)
    assistants.sort(compareStaffNav)
    other.sort(compareStaffNav)
    return { stylists, assistants, other }
  }, [filteredStaff])

  const selected = useMemo(
    () => staff.find((s) => s.id === selectedId) ?? null,
    [staff, selectedId],
  )

  const selectedSalesImportMeta = useMemo(() => {
    if (!selected) return undefined
    return salesImportMetaByStaffId.get(selected.id)
  }, [selected, salesImportMetaByStaffId])

  useEffect(() => {
    if (!selected) {
      setDraft(null)
      return
    }
    setDraft(draftFromRow(selected))
  }, [selected])

  useEffect(() => {
    if (filteredStaff.length === 0) {
      if (selectedId !== null) setSelectedId(null)
      return
    }
    if (selectedId != null && filteredStaff.some((s) => s.id === selectedId)) return
    setSelectedId(filteredStaff[0].id)
  }, [filteredStaff, selectedId])

  /**
   * Per-key dirty map across the full form. Drives the save flow's split
   * between "normal" (direct `updateStaffMember`) and "role/pay" (effective-
   * dated `apply_staff_role_assignment` via the modal).
   */
  const dirtyMap = useMemo<Partial<Record<keyof StaffFormDraft, boolean>>>(() => {
    if (!selected || !draft) return {}
    const base = draftFromRow(selected)
    const keys: (keyof StaffFormDraft)[] = [
      'full_name',
      'display_name',
      'primary_role',
      'secondary_roles',
      'remuneration_plan',
      'employment_type',
      'primary_location_id',
      'fte',
      'employment_start_date',
      'employment_end_date',
      'is_active',
      'notes',
      'contractor_company_name',
      'contractor_gst_registered',
      'contractor_ird_number',
      'contractor_street_address',
      'contractor_suburb',
      'contractor_city_postcode',
      'contractor_email',
      'contractor_invoice_code',
    ]
    const out: Partial<Record<keyof StaffFormDraft, boolean>> = {}
    for (const k of keys) {
      const a = draft[k]
      const b = base[k]
      let changed = false
      if (k === 'is_active' || k === 'contractor_gst_registered') {
        changed = a !== b
      } else {
        const an = typeof a === 'string' ? a.trim() : a
        const bn = typeof b === 'string' ? b.trim() : b
        changed = an !== bn
      }
      if (changed) out[k] = true
    }
    return out
  }, [selected, draft])

  const roleOrPayDirty = useMemo(
    () => ROLE_PAY_KEYS.some((k) => dirtyMap[k] === true),
    [dirtyMap],
  )

  const normalDirty = useMemo(
    () =>
      Object.keys(dirtyMap).some(
        (k) => !(ROLE_PAY_KEYS as readonly string[]).includes(k),
      ),
    [dirtyMap],
  )

  const dirty = roleOrPayDirty || normalDirty

  const saveMut = useMutation({
    mutationFn: async () => {
      if (!draft) return
      const fteTrimmed = draft.fte.trim()
      let fteValue: number | null = null
      if (fteTrimmed !== '') {
        const n = Number(fteTrimmed)
        if (!Number.isFinite(n)) {
          throw new Error('FTE must be a number (e.g. 1, 0.5, 0.8).')
        }
        fteValue = n
      }
      const payload: StaffMemberUpdatePayload = {
        id: draft.id,
        full_name: draft.full_name,
        display_name: draft.display_name || null,
        primary_role: draft.primary_role || null,
        secondary_roles: draft.secondary_roles || null,
        remuneration_plan: draft.remuneration_plan || null,
        employment_type: draft.employment_type,
        primary_location_id:
          draft.primary_location_id.trim() === '' ? null : draft.primary_location_id.trim(),
        fte: fteValue,
        employment_start_date: draft.employment_start_date || null,
        employment_end_date: draft.employment_end_date || null,
        is_active: draft.is_active,
        notes: draft.notes || null,
        contractor_company_name: draft.contractor_company_name || null,
        contractor_gst_registered: draft.contractor_gst_registered,
        contractor_ird_number: draft.contractor_ird_number || null,
        contractor_street_address: draft.contractor_street_address || null,
        contractor_suburb: draft.contractor_suburb || null,
        contractor_city_postcode: draft.contractor_city_postcode || null,
        contractor_email: draft.contractor_email || null,
        contractor_invoice_code: draft.contractor_invoice_code || null,
      }
      await updateStaffMember(payload)
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['staff-configuration'] })
      void queryClient.invalidateQueries({
        queryKey: ['admin-access-staff-location-lookup'],
      })
      void queryClient.invalidateQueries({ queryKey: ['remuneration-configuration'] })
    },
  })

  /**
   * Effective-dated save path. Used whenever any of `ROLE_PAY_KEYS` are
   * dirty. If normal (non-role/pay) fields are ALSO dirty, those are
   * persisted first via the existing `updateStaffMember` call but with
   * role/pay locked to the SELECTED (old) values — that way, if the
   * subsequent assignment apply fails, `staff_members` still reflects a
   * consistent role/pay state and the user can retry the modal without
   * having to undo their normal-field edits.
   */
  const applyAssignmentMut = useMutation({
    mutationFn: async (modalValues: { effectiveDate: string; reason: string }) => {
      if (!draft || !selected) return
      const fteTrimmed = draft.fte.trim()
      let newFte: number | null = null
      if (fteTrimmed !== '') {
        const n = Number(fteTrimmed)
        if (!Number.isFinite(n)) {
          throw new Error('FTE must be a number (e.g. 1, 0.5, 0.8).')
        }
        newFte = n
      }

      if (normalDirty) {
        const oldFteNum =
          selected.fte == null
            ? null
            : (() => {
                const n = Number(selected.fte)
                return Number.isFinite(n) ? n : null
              })()
        const lockedPayload: StaffMemberUpdatePayload = {
          id: draft.id,
          full_name: draft.full_name,
          display_name: draft.display_name || null,
          // Role/pay locked to the SELECTED row so this UPDATE only carries
          // non-role/pay edits. The RPC below will write the new role/pay.
          primary_role: selected.primary_role,
          secondary_roles: selected.secondary_roles,
          remuneration_plan: selected.remuneration_plan,
          employment_type: selected.employment_type,
          primary_location_id: selected.primary_location_id ?? null,
          fte: oldFteNum,
          // All other fields take their (potentially new) draft value:
          employment_start_date: draft.employment_start_date || null,
          employment_end_date: draft.employment_end_date || null,
          is_active: draft.is_active,
          notes: draft.notes || null,
          contractor_company_name: draft.contractor_company_name || null,
          contractor_gst_registered: draft.contractor_gst_registered,
          contractor_ird_number: draft.contractor_ird_number || null,
          contractor_street_address: draft.contractor_street_address || null,
          contractor_suburb: draft.contractor_suburb || null,
          contractor_city_postcode: draft.contractor_city_postcode || null,
          contractor_email: draft.contractor_email || null,
          contractor_invoice_code: draft.contractor_invoice_code || null,
        }
        await updateStaffMember(lockedPayload)
      }

      await applyStaffRoleAssignment({
        staffMemberId: draft.id,
        effectiveStartDate: modalValues.effectiveDate,
        primaryRole: draft.primary_role || null,
        secondaryRoles: draft.secondary_roles || null,
        employmentType: draft.employment_type,
        remunerationPlan: draft.remuneration_plan || null,
        fte: newFte,
        primaryLocationId:
          draft.primary_location_id.trim() === '' ? null : draft.primary_location_id.trim(),
        reason: modalValues.reason || null,
      })
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['staff-configuration'] })
      void queryClient.invalidateQueries({
        queryKey: ['admin-access-staff-location-lookup'],
      })
      void queryClient.invalidateQueries({ queryKey: ['remuneration-configuration'] })
      if (draft?.id) {
        void queryClient.invalidateQueries({
          queryKey: ['staff-role-assignments', draft.id],
        })
      }
      setApplyModalOpen(false)
    },
  })

  const [applyModalOpen, setApplyModalOpen] = useState(false)

  /**
   * Renderable diff of the role/pay fields that are about to change.
   * `primary_location_id` is resolved to a human-readable location name
   * using the `locations` lookup loaded by `useStaffConfiguration`.
   */
  const pendingRolePayChanges = useMemo<RoleAssignmentChange[]>(() => {
    if (!selected || !draft) return []
    const locName = (id: string | null | undefined): string | null => {
      const trimmed = (id ?? '').trim()
      if (trimmed === '') return null
      const hit = locations.find((l) => l.id === trimmed)
      return hit ? `${hit.name}${hit.code ? ` (${hit.code})` : ''}` : trimmed
    }
    const out: RoleAssignmentChange[] = []
    for (const key of ROLE_PAY_KEYS) {
      if (dirtyMap[key] !== true) continue
      const label = ROLE_PAY_LABELS[key]
      if (key === 'primary_location_id') {
        out.push({
          label,
          oldValue: locName(selected.primary_location_id ?? null),
          newValue: locName(draft.primary_location_id),
        })
      } else if (key === 'fte') {
        out.push({
          label,
          oldValue: selected.fte == null ? null : String(selected.fte),
          newValue: draft.fte === '' ? null : draft.fte,
        })
      } else if (key === 'employment_type') {
        out.push({
          label,
          oldValue: selected.employment_type ?? null,
          newValue: draft.employment_type,
        })
      } else {
        out.push({
          label,
          oldValue: (selected[key] as string | null) ?? null,
          newValue: (draft[key] as string) || null,
        })
      }
    }
    return out
  }, [selected, draft, dirtyMap, locations])

  const createMut = useMutation({
    mutationFn: () =>
      insertStaffMember({
        full_name: `New staff ${new Date().toISOString().slice(0, 16).replace('T', ' ')}`,
      }),
    onSuccess: (row) => {
      void queryClient.invalidateQueries({ queryKey: ['staff-configuration'] })
      void queryClient.invalidateQueries({
        queryKey: ['admin-access-staff-location-lookup'],
      })
      setSelectedId(row.id)
    },
  })

  const deleteMut = useMutation({
    mutationFn: (id: string) => deleteStaffMember(id),
    onSuccess: (_, deletedId) => {
      void queryClient.invalidateQueries({ queryKey: ['staff-configuration'] })
      void queryClient.invalidateQueries({
        queryKey: ['admin-access-staff-location-lookup'],
      })
      void queryClient.invalidateQueries({ queryKey: ['admin-access-mappings'] })
      void queryClient.invalidateQueries({ queryKey: ['remuneration-configuration'] })
      setSelectedId((cur) => (cur === deletedId ? null : cur))
    },
  })

  function doConfirmDeleteStaff() {
    const t = confirmDeleteStaff
    if (!t) return
    setConfirmDeleteStaff(null)
    deleteMut.mutate(t.id)
  }

  const remunerationOptions = useMemo(() => {
    const set = new Set(planNames)
    const current = draft?.remuneration_plan?.trim()
    if (current && !set.has(current)) set.add(current)
    return [...set].sort((a, b) => a.localeCompare(b))
  }, [planNames, draft?.remuneration_plan])

  const primaryLocationSelectOptions = useMemo(() => {
    const byId = new Map(locations.map((l) => [l.id, l]))
    const cur = draft?.primary_location_id?.trim()
    if (cur && !byId.has(cur)) {
      byId.set(cur, { id: cur, code: '', name: 'Current value (not in active list)' })
    }
    return [...byId.values()].sort((a, b) =>
      a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }),
    )
  }, [locations, draft?.primary_location_id])

  if (isLoading) {
    return (
      <div data-testid="staff-config-page">
        <LoadingState message="Loading staff…" testId="staff-config-loading" />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="staff-config-page">
        <ErrorState
          title="Could not load staff"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="staff-config-error"
        />
      </div>
    )
  }

  return (
    <div
      data-testid="staff-config-page"
      className="flex min-h-0 w-full flex-col lg:h-[calc(100dvh-7.5rem)] lg:min-h-0 lg:overflow-hidden"
    >
      <div className="flex min-h-0 flex-1 flex-col overflow-hidden">
        <div className="shrink-0 border-b border-slate-200/80 bg-slate-50/90 py-2 pl-2 pr-4 sm:py-2.5 sm:pl-3 sm:pr-6">
          <div className="rounded-xl border border-slate-200 bg-white p-3 shadow-sm sm:p-4">
            <div className="flex flex-wrap items-end gap-x-4 gap-y-3">
              <div className="w-full min-w-0 md:min-w-[14rem] md:flex-[2] md:basis-[min(100%,22rem)]">
                <label
                  className="block text-xs font-medium text-slate-600"
                  htmlFor="staff-filter-search"
                >
                  Name or role
                </label>
                <input
                  id="staff-filter-search"
                  type="search"
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder="Search…"
                  autoComplete="off"
                  className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                />
              </div>
              <div className="w-full shrink-0 sm:w-44">
                <label
                  className="block text-xs font-medium text-slate-600"
                  htmlFor="staff-filter-status"
                >
                  Status
                </label>
                <select
                  id="staff-filter-status"
                  value={statusFilter}
                  onChange={(e) => setStatusFilter(e.target.value as StatusFilter)}
                  className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                >
                  <option value="all">All</option>
                  <option value="active">Active</option>
                  <option value="inactive">Inactive</option>
                </select>
              </div>
              <div className="w-full shrink-0 sm:w-44">
                <label
                  className="block text-xs font-medium text-slate-600"
                  htmlFor="staff-filter-employment"
                >
                  Employment type
                </label>
                <select
                  id="staff-filter-employment"
                  value={employmentTypeFilter}
                  onChange={(e) =>
                    setEmploymentTypeFilter(e.target.value as 'all' | EmploymentKind)
                  }
                  className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                >
                  <option value="all">All</option>
                  <option value="Employee">Employee</option>
                  <option value="Contractor">Contractor</option>
                </select>
              </div>
              <div className="w-full shrink-0 sm:w-44">
                <label
                  className="block text-xs font-medium text-slate-600"
                  htmlFor="staff-filter-remuneration"
                >
                  Remuneration plan
                </label>
                <select
                  id="staff-filter-remuneration"
                  value={remunerationPlanFilter}
                  onChange={(e) => setRemunerationPlanFilter(e.target.value)}
                  className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                >
                  <option value="">All</option>
                  <option value="__none__">— None —</option>
                  {remunerationFilterOptions.map((name) => (
                    <option key={name} value={name}>
                      {name}
                    </option>
                  ))}
                </select>
              </div>
              <div className="w-full shrink-0 sm:w-44">
                <label
                  className="block text-xs font-medium text-slate-600"
                  htmlFor="staff-filter-primary-role"
                >
                  Primary role
                </label>
                <select
                  id="staff-filter-primary-role"
                  value={primaryRoleFilter}
                  onChange={(e) => setPrimaryRoleFilter(e.target.value)}
                  className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                >
                  <option value="">All</option>
                  {primaryRoleFilterOptions.map((role) => (
                    <option key={role} value={role}>
                      {role}
                    </option>
                  ))}
                </select>
              </div>
            </div>
          </div>
        </div>

        <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-hidden pb-4 pl-2 pr-4 pt-2 sm:pl-3 sm:pr-6 lg:flex-row lg:pt-3">
        <aside className="flex min-h-0 w-full shrink-0 flex-col border-b border-slate-200 bg-white px-3 py-3 shadow-sm max-h-[min(46vh,26rem)] sm:px-4 lg:max-h-none lg:h-full lg:w-72 lg:overflow-hidden lg:rounded-lg lg:border lg:border-slate-200 lg:py-4 lg:shadow-sm">
          <button
            type="button"
            onClick={() => void createMut.mutateAsync()}
            disabled={createMut.isPending}
            className="w-full shrink-0 rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:opacity-50"
          >
            {createMut.isPending ? 'Creating…' : 'Create new staff'}
          </button>
          {createMut.isError ? (
            <p className="mt-2 shrink-0 text-xs text-red-600">
              {createMut.error instanceof Error
                ? createMut.error.message
                : String(createMut.error)}
            </p>
          ) : null}
          <div className="mt-3 min-h-0 flex-1 overflow-y-auto pr-0.5">
            {filteredStaff.length === 0 ? (
              <p className="text-sm text-slate-500">No staff match your filters.</p>
            ) : (
              <div className="space-y-4 pb-2">
                <div>
                  <h3 className="sticky top-0 z-10 bg-white pb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
                    Stylists
                  </h3>
                  <ul className="mt-1 space-y-1">
                    {staffNavGroups.stylists.map((s) => (
                      <StaffNavRow
                        key={s.id}
                        member={s}
                        active={s.id === selectedId}
                        onSelect={setSelectedId}
                        locations={locations}
                      />
                    ))}
                  </ul>
                </div>
                <div>
                  <h3 className="sticky top-0 z-10 bg-white pb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
                    Assistants
                  </h3>
                  <ul className="mt-1 space-y-1">
                    {staffNavGroups.assistants.map((s) => (
                      <StaffNavRow
                        key={s.id}
                        member={s}
                        active={s.id === selectedId}
                        onSelect={setSelectedId}
                        locations={locations}
                      />
                    ))}
                  </ul>
                </div>
                <div>
                  <h3 className="sticky top-0 z-10 bg-white pb-1 text-xs font-semibold uppercase tracking-wide text-slate-500">
                    Admin
                  </h3>
                  <ul className="mt-1 space-y-1">
                    {staffNavGroups.other.map((s) => (
                      <StaffNavRow
                        key={s.id}
                        member={s}
                        active={s.id === selectedId}
                        onSelect={setSelectedId}
                        locations={locations}
                      />
                    ))}
                  </ul>
                </div>
              </div>
            )}
          </div>
        </aside>

        <div className="min-h-0 min-w-0 flex-1 overflow-y-auto pb-6 pt-0">
          <PageHeader
            title="Staff Configuration"
            description="Manage the staff records used by imports, commission calculations, and reporting."
          />

          <div
            className="mb-6 w-full rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950"
            role="status"
          >
            <span className="font-medium">Important: </span>
            Update staff details with care. Changes to roles, remuneration plans, and active
            status can affect downstream calculations and reporting.
          </div>

          <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
            {!selected || !draft ? (
              <p className="text-sm text-slate-600">Select a staff member, or create one.</p>
            ) : (
              <form
                className="space-y-6"
                onSubmit={(e) => {
                  e.preventDefault()
                  if (!draft) return
                  if (roleOrPayDirty) {
                    setApplyModalOpen(true)
                  } else if (normalDirty) {
                    void saveMut.mutateAsync()
                  }
                }}
              >
                <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="display_name">
                      Kitomba Display Name
                    </label>
                    <input
                      id="display_name"
                      value={draft.display_name}
                      onChange={(e) =>
                        setDraft((d) => (d ? { ...d, display_name: e.target.value } : d))
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                    <p className="mt-1 text-xs text-slate-500">
                      Kitomba / sales-import identifier: matched to display names on imported sale
                      lines.
                    </p>
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="full_name">
                      Full name <span className="text-red-600">*</span>
                    </label>
                    <input
                      id="full_name"
                      value={draft.full_name}
                      onChange={(e) =>
                        setDraft((d) => (d ? { ...d, full_name: e.target.value } : d))
                      }
                      required
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                    <p className="mt-1 text-xs text-slate-500">
                      Required. Use the person’s legal or payroll name for records.
                    </p>
                  </div>
                </div>

                <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="primary_role">
                      Primary role
                    </label>
                    <input
                      id="primary_role"
                      value={draft.primary_role}
                      onChange={(e) =>
                        setDraft((d) => (d ? { ...d, primary_role: e.target.value } : d))
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="secondary_roles">
                      Secondary roles
                    </label>
                    <input
                      id="secondary_roles"
                      value={draft.secondary_roles}
                      onChange={(e) =>
                        setDraft((d) => (d ? { ...d, secondary_roles: e.target.value } : d))
                      }
                      placeholder="e.g. Head of Training"
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>
                </div>

                <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="remuneration_plan">
                      Remuneration plan
                    </label>
                    <select
                      id="remuneration_plan"
                      value={draft.remuneration_plan}
                      onChange={(e) =>
                        setDraft((d) => (d ? { ...d, remuneration_plan: e.target.value } : d))
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    >
                      <option value="">— None —</option>
                      {remunerationOptions.map((name) => (
                        <option key={name} value={name}>
                          {name}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="emp_start">
                      Start date
                    </label>
                    <input
                      id="emp_start"
                      type="date"
                      value={draft.employment_start_date}
                      onChange={(e) =>
                        setDraft((d) =>
                          d ? { ...d, employment_start_date: e.target.value } : d,
                        )
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="emp_end">
                      End date
                    </label>
                    <input
                      id="emp_end"
                      type="date"
                      value={draft.employment_end_date}
                      onChange={(e) =>
                        setDraft((d) =>
                          d ? { ...d, employment_end_date: e.target.value } : d,
                        )
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>
                  <div>
                    <label
                      className="block text-sm font-medium text-slate-700"
                      htmlFor="employment_status"
                    >
                      Employment status
                    </label>
                    <select
                      id="employment_status"
                      value={draft.is_active ? 'active' : 'inactive'}
                      onChange={(e) =>
                        setDraft((d) =>
                          d ? { ...d, is_active: e.target.value === 'active' } : d,
                        )
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    >
                      <option value="active">Active</option>
                      <option value="inactive">Inactive</option>
                    </select>
                  </div>
                </div>

                <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
                  <div className="min-w-0 sm:col-span-2 xl:col-span-2">
                    <label className="block text-sm font-medium text-slate-700" htmlFor="employment_type">
                      Employment type
                    </label>
                    <select
                      id="employment_type"
                      value={draft.employment_type}
                      onChange={(e) =>
                        setDraft((d) =>
                          d
                            ? {
                                ...d,
                                employment_type: e.target.value as EmploymentKind,
                              }
                            : d,
                        )
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    >
                      <option value="Employee">Employee</option>
                      <option value="Contractor">Contractor</option>
                    </select>
                  </div>
                  <div className="min-w-0">
                    <label
                      className="block text-sm font-medium text-slate-700"
                      htmlFor="primary_location_id"
                    >
                      Primary location
                    </label>
                    <select
                      id="primary_location_id"
                      value={draft.primary_location_id}
                      onChange={(e) =>
                        setDraft((d) =>
                          d ? { ...d, primary_location_id: e.target.value } : d,
                        )
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    >
                      <option value="">— None —</option>
                      {primaryLocationSelectOptions.map((loc) => (
                        <option key={loc.id} value={loc.id}>
                          {loc.name}
                          {loc.code ? ` (${loc.code})` : ''}
                        </option>
                      ))}
                    </select>
                  </div>
                  <div className="min-w-0">
                    <label className="block text-sm font-medium text-slate-700" htmlFor="fte">
                      FTE
                    </label>
                    <input
                      id="fte"
                      type="number"
                      inputMode="decimal"
                      step="0.01"
                      min="0"
                      max="9.9999"
                      value={draft.fte}
                      onChange={(e) =>
                        setDraft((d) => (d ? { ...d, fte: e.target.value } : d))
                      }
                      placeholder="e.g. 1"
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>
                </div>

                {draft.employment_type === 'Contractor' ? (
                  <div className="space-y-3 border-t border-slate-100 pt-4">
                    <h3 className="text-base font-semibold text-slate-900">
                      Contractor Information
                    </h3>
                    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                      <div>
                        <label className="block text-sm font-medium text-slate-700" htmlFor="c_company">
                          Company Name
                        </label>
                        <input
                          id="c_company"
                          type="text"
                          value={draft.contractor_company_name}
                          onChange={(e) =>
                            setDraft((d) =>
                              d ? { ...d, contractor_company_name: e.target.value } : d,
                            )
                          }
                          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                        />
                        <p className="mt-1 text-xs text-slate-500">
                          Enter name of company, or employee name if a sole trader
                        </p>
                      </div>
                      <div className="flex flex-col gap-2 pt-0.5">
                        <span className="text-sm font-medium text-slate-700">GST Registered</span>
                        <label className="inline-flex cursor-pointer items-center gap-2 text-sm text-slate-800">
                          <input
                            id="c_gst"
                            type="checkbox"
                            checked={draft.contractor_gst_registered}
                            onChange={(e) =>
                              setDraft((d) =>
                                d
                                  ? { ...d, contractor_gst_registered: e.target.checked }
                                  : d,
                              )
                            }
                            className="rounded border-slate-300"
                          />
                          Registered for GST
                        </label>
                      </div>
                      <div>
                        <label className="block text-sm font-medium text-slate-700" htmlFor="c_ird">
                          IRD Number
                        </label>
                        <input
                          id="c_ird"
                          type="text"
                          value={draft.contractor_ird_number}
                          onChange={(e) =>
                            setDraft((d) =>
                              d ? { ...d, contractor_ird_number: e.target.value } : d,
                            )
                          }
                          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                        />
                        <p className="mt-1 text-xs text-slate-500">
                          Company IRD number for GST purposes, or employee name if sole trader
                        </p>
                      </div>
                      <div>
                        <label className="block text-sm font-medium text-slate-700" htmlFor="c_street">
                          Street Address
                        </label>
                        <input
                          id="c_street"
                          type="text"
                          value={draft.contractor_street_address}
                          onChange={(e) =>
                            setDraft((d) =>
                              d ? { ...d, contractor_street_address: e.target.value } : d,
                            )
                          }
                          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                        />
                      </div>
                      <div>
                        <label className="block text-sm font-medium text-slate-700" htmlFor="c_suburb">
                          Suburb
                        </label>
                        <input
                          id="c_suburb"
                          type="text"
                          value={draft.contractor_suburb}
                          onChange={(e) =>
                            setDraft((d) =>
                              d ? { ...d, contractor_suburb: e.target.value } : d,
                            )
                          }
                          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                        />
                      </div>
                      <div>
                        <label className="block text-sm font-medium text-slate-700" htmlFor="c_city">
                          City & Postcode
                        </label>
                        <input
                          id="c_city"
                          type="text"
                          value={draft.contractor_city_postcode}
                          onChange={(e) =>
                            setDraft((d) =>
                              d ? { ...d, contractor_city_postcode: e.target.value } : d,
                            )
                          }
                          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                        />
                      </div>
                      <div>
                        <label
                          className="block text-sm font-medium text-slate-700"
                          htmlFor="c_email"
                        >
                          Contractor Email
                        </label>
                        <input
                          id="c_email"
                          type="email"
                          value={draft.contractor_email}
                          onChange={(e) =>
                            setDraft((d) =>
                              d ? { ...d, contractor_email: e.target.value } : d,
                            )
                          }
                          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                          placeholder="optional"
                        />
                        <p className="mt-1 text-xs text-slate-500">
                          Optional. Shown on the contractor invoice when set.
                        </p>
                      </div>
                      <div>
                        <label
                          className="block text-sm font-medium text-slate-700"
                          htmlFor="c_invoice_code"
                        >
                          Contractor Invoice Code
                        </label>
                        <input
                          id="c_invoice_code"
                          type="text"
                          value={draft.contractor_invoice_code}
                          onChange={(e) =>
                            setDraft((d) =>
                              d
                                ? { ...d, contractor_invoice_code: e.target.value }
                                : d,
                            )
                          }
                          className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                          placeholder="e.g. EF"
                          maxLength={12}
                        />
                        <p className="mt-1 text-xs text-slate-500">
                          Short stable code used in invoice numbers (e.g.{' '}
                          <code className="rounded bg-slate-100 px-1">EF</code>{' '}
                          → <code className="rounded bg-slate-100 px-1">EF-25-0608</code>).
                        </p>
                      </div>
                    </div>
                  </div>
                ) : null}

                <div>
                  <label className="block text-sm font-medium text-slate-700" htmlFor="notes">
                    Notes
                  </label>
                  <textarea
                    id="notes"
                    value={draft.notes}
                    onChange={(e) =>
                      setDraft((d) => (d ? { ...d, notes: e.target.value } : d))
                    }
                    rows={3}
                    className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                  />
                </div>

                <div className="rounded-lg border border-slate-100 bg-slate-50/80 px-3 py-2 text-xs text-slate-600">
                  <p className="font-medium text-slate-800">Import metadata (read-only)</p>
                  <p className="mt-1">
                    First seen sale:{' '}
                    {formatLiveSaleSeenLine(selectedSalesImportMeta, 'first')}
                  </p>
                  <p>
                    Last seen sale:{' '}
                    {formatLiveSaleSeenLine(selectedSalesImportMeta, 'last')}
                  </p>
                </div>

                <div className="flex flex-wrap items-center justify-between gap-3 border-t border-slate-100 pt-4">
                  <div className="flex flex-wrap items-center gap-3">
                    <button
                      type="submit"
                      disabled={
                        saveMut.isPending || applyAssignmentMut.isPending || !dirty
                      }
                      className="rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      {saveMut.isPending
                        ? 'Saving…'
                        : roleOrPayDirty
                          ? 'Save changes…'
                          : 'Save changes'}
                    </button>
                    {roleOrPayDirty ? (
                      <span className="text-xs text-slate-500">
                        Role / pay changes will prompt for an effective date.
                      </span>
                    ) : null}
                    {saveMut.isError ? (
                      <span className="text-sm text-red-600">
                        {saveMut.error instanceof Error
                          ? saveMut.error.message
                          : String(saveMut.error)}
                      </span>
                    ) : null}
                  </div>
                  <button
                    type="button"
                    disabled={
                      deleteMut.isPending || saveMut.isPending || createMut.isPending
                    }
                    onClick={() => {
                      if (!draft) return
                      const disp = draft.display_name.trim()
                      const full = draft.full_name.trim()
                      const label =
                        disp !== '' ? disp : full !== '' ? full : 'this staff member'
                      setConfirmDeleteStaff({ id: draft.id, label })
                    }}
                    className="rounded-md border border-rose-200 bg-white px-4 py-2 text-sm font-medium text-rose-700 hover:bg-rose-50 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    {deleteMut.isPending ? 'Deleting…' : 'Delete staff'}
                  </button>
                </div>
                {deleteMut.isError ? (
                  <p className="mt-2 text-sm text-red-600">
                    {deleteMut.error instanceof Error
                      ? deleteMut.error.message
                      : String(deleteMut.error)}
                  </p>
                ) : null}
              </form>
            )}
          </section>

          {selected ? (
            <StaffRoleAssignmentHistorySection staffMemberId={selected.id} />
          ) : null}
        </div>
        </div>
      </div>

      <ApplyRoleAssignmentModal
        open={applyModalOpen}
        staffDisplayName={
          selected
            ? (selected.display_name?.trim() ||
                selected.full_name?.trim() ||
                'this staff member')
            : ''
        }
        pendingChanges={pendingRolePayChanges}
        submitting={applyAssignmentMut.isPending}
        submitError={
          applyAssignmentMut.isError
            ? applyAssignmentMut.error instanceof Error
              ? applyAssignmentMut.error.message
              : String(applyAssignmentMut.error)
            : null
        }
        onClose={() => {
          if (applyAssignmentMut.isPending) return
          setApplyModalOpen(false)
          applyAssignmentMut.reset()
        }}
        onConfirm={(values) => {
          void applyAssignmentMut.mutateAsync(values)
        }}
      />

      <ConfirmDialog
        open={confirmDeleteStaff != null}
        title={
          confirmDeleteStaff
            ? `Delete "${confirmDeleteStaff.label}"?`
            : 'Delete staff?'
        }
        description="This permanently removes the staff record, any user access mappings for them, and KPI rows tied to this person (targets, monthly values, manual inputs, upload rows, capacity). Historical sales lines are unchanged. This cannot be undone."
        confirmLabel="Delete staff"
        tone="danger"
        onConfirm={doConfirmDeleteStaff}
        onClose={() => setConfirmDeleteStaff(null)}
        testId="staff-config-delete-confirm"
      />
    </div>
  )
}

/* ------------------------------------------------------------------------- */
/* Role and pay history (read-only)                                          */
/* ------------------------------------------------------------------------- */

function formatHistoryDate(iso: string | null | undefined): string {
  if (!iso) return '—'
  return formatShortDate(iso)
}

function formatHistoryFte(fte: number | string | null | undefined): string {
  if (fte == null || fte === '') return '—'
  const n = typeof fte === 'number' ? fte : Number(fte)
  if (!Number.isFinite(n)) return String(fte)
  // Match the Staff form's editing style (trim trailing zeros).
  return n
    .toFixed(4)
    .replace(/\.?0+$/, '')
}

function formatHistoryText(v: string | null | undefined): string {
  const s = (v ?? '').trim()
  return s === '' ? '—' : s
}

function HistoryRow({
  row,
  showUndoColumn,
  canUndoThisRow,
  undoBusy,
  onUndoClick,
}: {
  row: StaffRoleAssignmentRow
  /** True when ANY row in the table renders the actions column. */
  showUndoColumn: boolean
  /** True only for the single row eligible for undo (latest open, count > 1). */
  canUndoThisRow: boolean
  undoBusy: boolean
  onUndoClick: () => void
}) {
  const isOpen = row.effective_end_date == null
  return (
    <tr className="align-top">
      <td className="px-3 py-2 text-xs text-slate-700">
        <div className="font-medium text-slate-900">
          {formatHistoryDate(row.effective_start_date)}
        </div>
        <div className="text-slate-500">
          to{' '}
          {isOpen ? (
            <span className="font-medium text-emerald-700">present</span>
          ) : (
            formatHistoryDate(row.effective_end_date)
          )}
        </div>
      </td>
      <td className="px-3 py-2 text-xs text-slate-800">
        {formatHistoryText(row.primary_role)}
      </td>
      <td className="px-3 py-2 text-xs text-slate-800">
        {formatHistoryText(row.employment_type)}
      </td>
      <td className="px-3 py-2 text-xs text-slate-800">
        {formatHistoryText(row.remuneration_plan)}
      </td>
      <td className="px-3 py-2 text-right text-xs text-slate-800 tabular-nums">
        {formatHistoryFte(row.fte)}
      </td>
      <td className="px-3 py-2 text-xs text-slate-800">
        {formatHistoryText(row.primary_location_name ?? null)}
      </td>
      <td className="px-3 py-2 text-xs text-slate-600">
        {formatHistoryText(row.reason)}
      </td>
      {showUndoColumn ? (
        <td className="px-3 py-2 text-right text-xs">
          {canUndoThisRow ? (
            <button
              type="button"
              onClick={onUndoClick}
              disabled={undoBusy}
              className="rounded-md border border-rose-200 bg-white px-2.5 py-1 text-xs font-medium text-rose-700 hover:bg-rose-50 disabled:cursor-not-allowed disabled:opacity-50"
              data-testid="staff-history-undo"
              title="Remove this latest change and reopen the previous assignment"
            >
              {undoBusy ? 'Undoing…' : 'Undo'}
            </button>
          ) : null}
        </td>
      ) : null}
    </tr>
  )
}

function StaffRoleAssignmentHistorySection({
  staffMemberId,
}: {
  staffMemberId: string
}) {
  const queryClient = useQueryClient()
  const { data, isLoading, isError, error, refetch } =
    useStaffRoleAssignments(staffMemberId)

  const [confirmUndo, setConfirmUndo] = useState<{ assignmentId: string } | null>(null)

  // The single row eligible for undo: the open row, only when there is
  // more than one history row for this staff member. Older / middle rows
  // can not be deleted through the UI (or through the RPC).
  const undoableRowId = useMemo<string | null>(() => {
    if (!data || data.length < 2) return null
    const openRows = data.filter((r) => r.effective_end_date == null)
    if (openRows.length !== 1) return null
    return openRows[0].id
  }, [data])

  const undoMut = useMutation({
    mutationFn: async (assignmentId: string) => {
      return undoLatestStaffRoleAssignment({
        staffMemberId,
        assignmentId,
        reason: null,
      })
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['staff-configuration'] })
      void queryClient.invalidateQueries({
        queryKey: ['admin-access-staff-location-lookup'],
      })
      void queryClient.invalidateQueries({ queryKey: ['remuneration-configuration'] })
      void queryClient.invalidateQueries({
        queryKey: ['staff-role-assignments', staffMemberId],
      })
    },
  })

  function doConfirmUndo() {
    const t = confirmUndo
    if (!t) return
    setConfirmUndo(null)
    void undoMut.mutateAsync(t.assignmentId)
  }

  const showUndoColumn = undoableRowId != null

  return (
    <section
      className="mt-6 rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6"
      data-testid="staff-history-section"
    >
      <header className="flex items-start justify-between gap-3">
        <div>
          <h2 className="text-base font-semibold text-slate-900">
            Role and pay history
          </h2>
          <p className="mt-1 text-xs text-slate-600">
            Effective-dated record of role, remuneration plan, employment type,
            FTE, and primary location. Commission and KPI calculations use these
            values as at the sale date. Edits to role / pay fields above open
            the apply-change dialog and add a new entry here.
          </p>
        </div>
      </header>

      {isLoading ? (
        <div className="mt-4">
          <LoadingState message="Loading history…" testId="staff-history-loading" />
        </div>
      ) : isError ? (
        <div className="mt-4">
          <ErrorState
            title="Could not load history"
            error={error instanceof Error ? error : null}
            message={
              error instanceof Error ? error.message : String(error ?? 'Unknown error')
            }
            onRetry={() => void refetch()}
            testId="staff-history-error"
          />
        </div>
      ) : !data || data.length === 0 ? (
        <p className="mt-4 text-sm text-slate-500">
          No role / pay history yet for this staff member.
        </p>
      ) : (
        <>
          <div className="mt-4 overflow-x-auto">
            <table className="min-w-full divide-y divide-slate-200">
              <thead className="bg-slate-50/80">
                <tr>
                  <th
                    scope="col"
                    className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                  >
                    Effective
                  </th>
                  <th
                    scope="col"
                    className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                  >
                    Primary role
                  </th>
                  <th
                    scope="col"
                    className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                  >
                    Employment type
                  </th>
                  <th
                    scope="col"
                    className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                  >
                    Remuneration plan
                  </th>
                  <th
                    scope="col"
                    className="px-3 py-2 text-right text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                  >
                    FTE
                  </th>
                  <th
                    scope="col"
                    className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                  >
                    Primary location
                  </th>
                  <th
                    scope="col"
                    className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                  >
                    Reason
                  </th>
                  {showUndoColumn ? (
                    <th
                      scope="col"
                      className="px-3 py-2 text-right text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                    >
                      Actions
                    </th>
                  ) : null}
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {data.map((row) => (
                  <HistoryRow
                    key={row.id}
                    row={row}
                    showUndoColumn={showUndoColumn}
                    canUndoThisRow={row.id === undoableRowId}
                    undoBusy={
                      undoMut.isPending && undoMut.variables === row.id
                    }
                    onUndoClick={() => setConfirmUndo({ assignmentId: row.id })}
                  />
                ))}
              </tbody>
            </table>
          </div>
          {undoMut.isError ? (
            <p
              className="mt-3 text-sm text-red-600"
              role="alert"
              data-testid="staff-history-undo-error"
            >
              {undoMut.error instanceof Error
                ? undoMut.error.message
                : String(undoMut.error)}
            </p>
          ) : null}
        </>
      )}

      <ConfirmDialog
        open={confirmUndo != null}
        title="Undo latest role / pay change?"
        description="This will remove the latest role/pay change and restore the previous role/pay setup as the current profile. Payroll, commission, and KPI calculations from this date forward will revert to the previous values. This cannot be undone."
        confirmLabel="Undo latest change"
        cancelLabel="Keep change"
        tone="danger"
        onConfirm={doConfirmUndo}
        onClose={() => setConfirmUndo(null)}
        testId="staff-history-undo-confirm"
      />
    </section>
  )
}
