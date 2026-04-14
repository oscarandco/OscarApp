import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useStaffConfiguration } from '@/features/admin/hooks/useStaffConfiguration'
import type { StaffMemberRow } from '@/features/admin/types/staffConfiguration'
import {
  insertStaffMember,
  updateStaffMember,
  type StaffMemberUpdatePayload,
} from '@/lib/staffMembersApi'
import { queryErrorDetail } from '@/lib/queryError'

type StatusFilter = 'all' | 'active' | 'inactive'

/** Form state: string fields for inputs; maps to `StaffMemberUpdatePayload` on save. */
type StaffFormDraft = Omit<
  StaffMemberUpdatePayload,
  | 'display_name'
  | 'primary_role'
  | 'secondary_roles'
  | 'remuneration_plan'
  | 'employment_type'
  | 'notes'
> & {
  display_name: string
  primary_role: string
  secondary_roles: string
  remuneration_plan: string
  employment_type: string
  employment_start_date: string
  employment_end_date: string
  notes: string
  fteInput: string
}

function isoDateToInput(iso: string | null | undefined): string {
  if (!iso) return ''
  return iso.slice(0, 10)
}

function parseFte(s: string): number | null {
  const t = s.trim()
  if (t === '') return null
  const n = Number(t)
  if (Number.isNaN(n)) return null
  return Math.min(1, Math.max(0, n))
}

function draftFromRow(row: StaffMemberRow): StaffFormDraft {
  const fteNum =
    row.fte == null || row.fte === ''
      ? null
      : typeof row.fte === 'number'
        ? row.fte
        : Number(row.fte)
  return {
    id: row.id,
    full_name: row.full_name,
    display_name: row.display_name ?? '',
    primary_role: row.primary_role ?? '',
    secondary_roles: row.secondary_roles ?? '',
    remuneration_plan: row.remuneration_plan ?? '',
    employment_type: row.employment_type ?? '',
    fte: fteNum != null && !Number.isNaN(fteNum) ? fteNum : null,
    fteInput: fteNum != null && !Number.isNaN(fteNum) ? String(fteNum) : '',
    employment_start_date: isoDateToInput(row.employment_start_date),
    employment_end_date: isoDateToInput(row.employment_end_date),
    is_active: row.is_active,
    notes: row.notes ?? '',
  }
}

export function StaffConfigurationPage() {
  const queryClient = useQueryClient()
  const { data, isLoading, isError, error, refetch } = useStaffConfiguration()

  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('all')
  const [draft, setDraft] = useState<StaffFormDraft | null>(null)

  const staff = data?.staff ?? []
  const planNames = data?.planNames ?? []

  const filteredStaff = useMemo(() => {
    const q = search.trim().toLowerCase()
    return staff.filter((s) => {
      if (statusFilter === 'active' && !s.is_active) return false
      if (statusFilter === 'inactive' && s.is_active) return false
      if (!q) return true
      const hay = `${s.full_name} ${s.display_name ?? ''} ${s.primary_role ?? ''}`.toLowerCase()
      return hay.includes(q)
    })
  }, [staff, search, statusFilter])

  const selected = useMemo(
    () => staff.find((s) => s.id === selectedId) ?? null,
    [staff, selectedId],
  )

  useEffect(() => {
    if (!selected) {
      setDraft(null)
      return
    }
    setDraft(draftFromRow(selected))
  }, [selected])

  useEffect(() => {
    if (staff.length === 0) {
      setSelectedId(null)
      return
    }
    if (selectedId != null && staff.some((s) => s.id === selectedId)) return
    setSelectedId(staff[0].id)
  }, [staff, selectedId])

  const dirty = useMemo(() => {
    if (!selected || !draft) return false
    const base = draftFromRow(selected)
    const keys: (keyof StaffFormDraft)[] = [
      'full_name',
      'display_name',
      'primary_role',
      'secondary_roles',
      'remuneration_plan',
      'employment_type',
      'employment_start_date',
      'employment_end_date',
      'is_active',
      'notes',
    ]
    for (const k of keys) {
      const a = draft[k]
      const b = base[k]
      const an = typeof a === 'string' ? a.trim() : a
      const bn = typeof b === 'string' ? b.trim() : b
      if (an !== bn) return true
    }
    if (parseFte(draft.fteInput) !== parseFte(base.fteInput)) return true
    return false
  }, [selected, draft])

  const saveMut = useMutation({
    mutationFn: async () => {
      if (!draft) return
      const fte = parseFte(draft.fteInput)
      const payload: StaffMemberUpdatePayload = {
        id: draft.id,
        full_name: draft.full_name,
        display_name: draft.display_name || null,
        primary_role: draft.primary_role || null,
        secondary_roles: draft.secondary_roles || null,
        remuneration_plan: draft.remuneration_plan || null,
        employment_type: draft.employment_type || null,
        fte,
        employment_start_date: draft.employment_start_date || null,
        employment_end_date: draft.employment_end_date || null,
        is_active: draft.is_active,
        notes: draft.notes || null,
      }
      await updateStaffMember(payload)
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['staff-configuration'] })
      void queryClient.invalidateQueries({ queryKey: ['remuneration-configuration'] })
    },
  })

  const createMut = useMutation({
    mutationFn: () =>
      insertStaffMember({
        full_name: `New staff ${new Date().toISOString().slice(0, 16).replace('T', ' ')}`,
      }),
    onSuccess: (row) => {
      void queryClient.invalidateQueries({ queryKey: ['staff-configuration'] })
      setSelectedId(row.id)
    },
  })

  const remunerationOptions = useMemo(() => {
    const set = new Set(planNames)
    const current = draft?.remuneration_plan?.trim()
    if (current && !set.has(current)) set.add(current)
    return [...set].sort((a, b) => a.localeCompare(b))
  }, [planNames, draft?.remuneration_plan])

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
      className="flex min-h-0 w-full flex-col lg:h-[calc(100dvh-7.5rem)] lg:min-h-0 lg:flex-row lg:overflow-hidden"
    >
      <aside className="flex min-h-0 w-full shrink-0 flex-col border-b border-slate-200 bg-white px-4 py-4 shadow-sm max-h-[min(42vh,22rem)] lg:max-h-none lg:h-full lg:w-72 lg:overflow-hidden lg:rounded-none lg:border-b-0 lg:border-r lg:shadow-none">
        <h2 className="text-sm font-semibold text-slate-900">Staff</h2>
        <label className="mt-3 block text-xs font-medium text-slate-600" htmlFor="staff-search">
          Search
        </label>
        <input
          id="staff-search"
          type="search"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Name or role…"
          autoComplete="off"
          className="mt-1 w-full rounded-md border border-slate-300 px-2 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
        />
        <label className="mt-3 block text-xs font-medium text-slate-600" htmlFor="staff-status-filter">
          Status
        </label>
        <select
          id="staff-status-filter"
          value={statusFilter}
          onChange={(e) => setStatusFilter(e.target.value as StatusFilter)}
          className="mt-1 w-full rounded-md border border-slate-300 px-2 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
        >
          <option value="all">All</option>
          <option value="active">Active</option>
          <option value="inactive">Inactive</option>
        </select>
        <button
          type="button"
          onClick={() => void createMut.mutateAsync()}
          disabled={createMut.isPending}
          className="mt-3 w-full rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:opacity-50"
        >
          {createMut.isPending ? 'Creating…' : 'Create new staff'}
        </button>
        {createMut.isError ? (
          <p className="mt-2 text-xs text-red-600">
            {createMut.error instanceof Error
              ? createMut.error.message
              : String(createMut.error)}
          </p>
        ) : null}
        <ul className="mt-4 min-h-0 flex-1 space-y-1 overflow-y-auto">
          {filteredStaff.length === 0 ? (
            <li className="text-sm text-slate-500">No staff match your filters.</li>
          ) : (
            filteredStaff.map((s) => {
              const active = s.id === selectedId
              const disp = s.display_name?.trim() ?? ''
              const full = (s.full_name ?? '').trim()
              const showSecondary =
                disp !== '' &&
                full !== '' &&
                disp.toLowerCase() !== full.toLowerCase()
              const primary = disp === '' ? full : disp
              return (
                <li key={s.id}>
                  <button
                    type="button"
                    onClick={() => setSelectedId(s.id)}
                    className={`flex w-full items-center justify-between gap-2 rounded-lg border px-3 py-2.5 text-left text-sm transition ${
                      active
                        ? 'border-violet-300 bg-violet-50 text-violet-950'
                        : 'border-transparent bg-slate-50/80 text-slate-800 hover:border-slate-200 hover:bg-white'
                    }`}
                  >
                    <span className="block min-w-0 flex-1 truncate text-left">
                      <span className="font-medium text-slate-900">{primary}</span>
                      {showSecondary ? (
                        <span className="text-xs font-normal text-slate-500">
                          {' '}
                          ({full})
                        </span>
                      ) : null}
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
            })
          )}
        </ul>
      </aside>

      <div className="min-h-0 min-w-0 flex-1 overflow-y-auto px-4 pb-8 pt-4 sm:px-6 lg:py-6 lg:pl-8 lg:pr-8">
        <div className="mx-auto w-full max-w-7xl">
          <PageHeader
            title="Staff Configuration"
            description="Manage the staff records used by imports, commission calculations, and reporting."
          />

          <div className="mb-6 rounded-lg border border-slate-200 bg-slate-50/90 px-4 py-3 text-sm text-slate-800 shadow-sm">
            <p className="font-semibold text-slate-900">How it works</p>
            <ol className="mt-2 list-decimal space-y-1 pl-5 text-slate-700">
              <li>Staff records are matched during sales import and downstream calculations.</li>
              <li>Each staff member can be assigned a remuneration plan.</li>
              <li>Access Management links logins to these staff records.</li>
              <li>Changes here affect how staff appear in commission and reporting flows.</li>
            </ol>
          </div>

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
                className="space-y-5"
                onSubmit={(e) => {
                  e.preventDefault()
                  void saveMut.mutateAsync()
                }}
              >
                <div className="grid gap-4 sm:grid-cols-2">
                  <div className="sm:col-span-2">
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
                    <p className="mt-1 text-xs text-slate-500">Unique in the system; used for matching.</p>
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="display_name">
                      Display name
                    </label>
                    <input
                      id="display_name"
                      value={draft.display_name}
                      onChange={(e) =>
                        setDraft((d) => (d ? { ...d, display_name: e.target.value } : d))
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>
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
                  <div className="sm:col-span-2">
                    <label className="block text-sm font-medium text-slate-700" htmlFor="secondary_roles">
                      Secondary roles
                    </label>
                    <input
                      id="secondary_roles"
                      value={draft.secondary_roles}
                      onChange={(e) =>
                        setDraft((d) => (d ? { ...d, secondary_roles: e.target.value } : d))
                      }
                      placeholder="e.g. comma-separated"
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>
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
                    <p className="mt-1 text-xs text-slate-500">
                      Must match a plan name from Remuneration Configuration.
                    </p>
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="employment_type">
                      Employment type
                    </label>
                    <input
                      id="employment_type"
                      value={draft.employment_type}
                      onChange={(e) =>
                        setDraft((d) => (d ? { ...d, employment_type: e.target.value } : d))
                      }
                      className="mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="fte">
                      FTE
                    </label>
                    <input
                      id="fte"
                      type="number"
                      min={0}
                      max={1}
                      step={0.01}
                      value={draft.fteInput}
                      onChange={(e) => {
                        const v = e.target.value
                        setDraft((d) =>
                          d ? { ...d, fteInput: v, fte: parseFte(v) } : d,
                        )
                      }}
                      className="mt-1 w-full max-w-[12rem] rounded-md border border-slate-300 px-3 py-2 text-sm tabular-nums shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                    <p className="mt-1 text-xs text-slate-500">Full-time equivalent (0–1).</p>
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
                      className="mt-1 w-full max-w-[12rem] rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
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
                      className="mt-1 w-full max-w-[12rem] rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>
                  <div className="flex items-center gap-2 sm:col-span-2">
                    <input
                      id="is_active"
                      type="checkbox"
                      checked={draft.is_active}
                      onChange={(e) =>
                        setDraft((d) => (d ? { ...d, is_active: e.target.checked } : d))
                      }
                      className="rounded border-slate-300"
                    />
                    <label htmlFor="is_active" className="text-sm font-medium text-slate-800">
                      Active
                    </label>
                  </div>
                </div>

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
                    {selected.first_seen_sale_date
                      ? isoDateToInput(selected.first_seen_sale_date)
                      : '—'}
                  </p>
                  <p>
                    Last seen sale:{' '}
                    {selected.last_seen_sale_date
                      ? isoDateToInput(selected.last_seen_sale_date)
                      : '—'}
                  </p>
                </div>

                <div className="flex flex-wrap items-center gap-3 border-t border-slate-100 pt-4">
                  <button
                    type="submit"
                    disabled={saveMut.isPending || !dirty}
                    className="rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    {saveMut.isPending ? 'Saving…' : 'Save changes'}
                  </button>
                  {saveMut.isError ? (
                    <span className="text-sm text-red-600">
                      {saveMut.error instanceof Error
                        ? saveMut.error.message
                        : String(saveMut.error)}
                    </span>
                  ) : null}
                </div>
              </form>
            )}
          </section>
        </div>
      </div>
    </div>
  )
}
