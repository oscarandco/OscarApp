import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import {
  staffCountForPlan,
  useRemunerationConfiguration,
} from '@/features/admin/hooks/useRemunerationConfiguration'
import {
  REMUNERATION_CAN_USE_ASSISTANTS_DESCRIPTION,
  REMUNERATION_CATEGORY_CARD_TITLE,
  REMUNERATION_CATEGORY_DESCRIPTION,
  REMUNERATION_COMMISSION_CATEGORIES,
  REMUNERATION_PLAN_SPECIFIC_COMMISSION_CATEGORIES,
  REMUNERATION_STANDARD_COMMISSION_CATEGORIES,
  type RemunerationCommissionCategory,
  type RemunerationPlanWithRates,
} from '@/features/admin/types/remuneration'
import {
  deleteRemunerationPlanIfUnused,
  fetchStaffForRemunerationPlan,
  insertRemunerationPlan,
  updateRemunerationPlanHeader,
  upsertRemunerationPlanRates,
} from '@/lib/remunerationPlansApi'
import { queryErrorDetail } from '@/lib/queryError'

function rateToPercent(rate: unknown): number {
  if (rate == null || rate === '') return 0
  const n = typeof rate === 'number' ? rate : Number(rate)
  if (Number.isNaN(n)) return 0
  return Math.round(n * 10_000) / 100
}

function percentToFraction(percent: number): number {
  if (Number.isNaN(percent)) return 0
  return Math.min(1, Math.max(0, percent / 100))
}

function CommissionRateCard(props: {
  cat: RemunerationCommissionCategory
  value: number
  onChange: (next: number) => void
}) {
  const { cat, value, onChange } = props
  return (
    <div className="flex h-full min-h-[12.5rem] flex-col rounded-xl border border-slate-200 bg-slate-50/90 p-4 shadow-sm">
      <h3 className="text-sm font-semibold text-slate-900">
        {REMUNERATION_CATEGORY_CARD_TITLE[cat]}
      </h3>
      <div className="mt-3">
        <label className="sr-only" htmlFor={`rem-rate-${cat}`}>
          {REMUNERATION_CATEGORY_CARD_TITLE[cat]} percentage
        </label>
        <div className="flex items-center gap-2">
          <input
            id={`rem-rate-${cat}`}
            type="number"
            min={0}
            max={100}
            step={0.01}
            value={value}
            onChange={(e) => {
              const v = Number(e.target.value)
              onChange(Number.isNaN(v) ? 0 : v)
            }}
            className="w-full min-w-0 max-w-[9rem] rounded-md border border-slate-300 bg-white px-3 py-2 text-sm tabular-nums shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
          />
          <span className="shrink-0 text-sm text-slate-500">%</span>
        </div>
        <p className="mt-1 text-[11px] text-slate-500">0–100, applied to ex GST line value</p>
      </div>
      <p className="mt-auto pt-3 text-xs leading-relaxed text-slate-600">
        {REMUNERATION_CATEGORY_DESCRIPTION[cat]}
      </p>
    </div>
  )
}

/** Percent 0–100 per category for form state. */
function percentsRecordFromPlan(plan: RemunerationPlanWithRates): Record<string, number> {
  const out: Record<string, number> = {}
  for (const cat of REMUNERATION_COMMISSION_CATEGORIES) {
    out[cat] = 0
  }
  for (const r of plan.rates) {
    const k = r.commission_category
    if (k && k in out) {
      out[k] = rateToPercent(r.rate)
    }
  }
  return out
}

export function RemunerationConfigurationPage() {
  const queryClient = useQueryClient()
  const { data, isLoading, isError, error, refetch } = useRemunerationConfiguration()

  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [draftName, setDraftName] = useState('')
  const [draftAssistants, setDraftAssistants] = useState(false)
  const [draftNotes, setDraftNotes] = useState('')
  const [draftPercents, setDraftPercents] = useState<Record<string, number>>({})
  const [deleteSuccess, setDeleteSuccess] = useState<string | null>(null)

  const plans = data?.plans ?? []
  const staffCounts = data?.staffCounts ?? []

  const filteredPlans = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return plans
    return plans.filter((p) => p.plan_name.toLowerCase().includes(q))
  }, [plans, search])

  const selected = useMemo(
    () => plans.find((p) => p.id === selectedId) ?? null,
    [plans, selectedId],
  )

  useEffect(() => {
    if (!selected) return
    setDraftName(selected.plan_name)
    setDraftAssistants(selected.can_use_assistants === true)
    setDraftNotes(selected.conditions_text ?? '')
    setDraftPercents(percentsRecordFromPlan(selected))
  }, [selected])

  useEffect(() => {
    if (plans.length === 0) {
      setSelectedId(null)
      return
    }
    if (selectedId != null && plans.some((p) => p.id === selectedId)) return
    setSelectedId(plans[0].id)
  }, [plans, selectedId])

  const staffQuery = useQuery({
    queryKey: ['remuneration-plan-staff', selected?.plan_name ?? ''],
    queryFn: () => fetchStaffForRemunerationPlan(selected!.plan_name),
    enabled: Boolean(selected?.plan_name?.trim()),
  })

  const saveMut = useMutation({
    mutationFn: async () => {
      if (!selected) return
      await updateRemunerationPlanHeader({
        id: selected.id,
        plan_name: draftName,
        can_use_assistants: draftAssistants,
        conditions_text: draftNotes.trim() === '' ? null : draftNotes.trim(),
      })
      const rates: Partial<Record<RemunerationCommissionCategory, number>> = {}
      for (const cat of REMUNERATION_COMMISSION_CATEGORIES) {
        rates[cat] = percentToFraction(draftPercents[cat] ?? 0)
      }
      await upsertRemunerationPlanRates({
        remuneration_plan_id: selected.id,
        rates,
      })
    },
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ['remuneration-configuration'] })
      void queryClient.invalidateQueries({ queryKey: ['remuneration-plan-staff'] })
    },
  })

  const createMut = useMutation({
    mutationFn: () =>
      insertRemunerationPlan({
        planName: `New plan ${new Date().toISOString().slice(0, 16).replace('T', ' ')}`,
      }),
    onSuccess: (row) => {
      void queryClient.invalidateQueries({ queryKey: ['remuneration-configuration'] })
      setSelectedId(row.id)
    },
  })

  const linkedStaffCount = selected
    ? staffCountForPlan(selected, staffCounts)
    : 0
  const canDeletePlan = Boolean(selected && linkedStaffCount === 0)

  const deleteMut = useMutation({
    mutationFn: (planId: string) => deleteRemunerationPlanIfUnused(planId),
    onSuccess: async () => {
      setDeleteSuccess('Plan deleted.')
      window.setTimeout(() => setDeleteSuccess(null), 5000)
      await queryClient.invalidateQueries({ queryKey: ['remuneration-configuration'] })
      await queryClient.invalidateQueries({ queryKey: ['remuneration-plan-staff'] })
    },
  })

  const dirty = useMemo(() => {
    if (!selected) return false
    if (draftName.trim() !== selected.plan_name) return true
    if ((selected.can_use_assistants === true) !== draftAssistants) return true
    if ((selected.conditions_text ?? '') !== draftNotes) return true
    const base = percentsRecordFromPlan(selected)
    for (const cat of REMUNERATION_COMMISSION_CATEGORIES) {
      if (Math.abs((draftPercents[cat] ?? 0) - (base[cat] ?? 0)) > 0.0001) {
        return true
      }
    }
    return false
  }, [selected, draftName, draftAssistants, draftNotes, draftPercents])

  if (isLoading) {
    return (
      <div data-testid="remuneration-config-page">
        <LoadingState
          message="Loading remuneration plans…"
          testId="remuneration-config-loading"
        />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="remuneration-config-page">
        <ErrorState
          title="Could not load remuneration plans"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="remuneration-config-error"
        />
      </div>
    )
  }

  return (
    <div data-testid="remuneration-config-page" className="w-full">
      <div className="w-full max-w-7xl px-4 pb-8 sm:px-6 lg:px-8">
      <PageHeader
        title="Remuneration Configuration"
        description="Set up the remuneration plans used by the app to calculate commission and pay outcomes from imported sales data."
      />

      <div className="mb-6 w-full rounded-lg border border-slate-200 bg-slate-50/90 px-4 py-3 text-sm text-slate-800 shadow-sm">
        <p className="font-semibold text-slate-900">How it works</p>
        <ol className="mt-2 list-decimal space-y-1 pl-5 text-slate-700">
          <li>Staff members are assigned a remuneration plan on their staff profile.</li>
          <li>Products and services are classified into commission categories elsewhere.</li>
          <li>The percentages on this page are applied to ex GST values when calculating commission.</li>
          <li>
            Results flow through to weekly payroll, line detail, and admin reporting.
          </li>
        </ol>
      </div>

      <div
        className="mb-6 w-full rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-950"
        role="status"
      >
        <span className="font-medium">Important: </span>
        Changes to remuneration plans affect downstream commission calculations and
        reporting. Update with care.
      </div>

      {deleteSuccess ? (
        <div
          className="mb-6 w-full rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-950"
          role="status"
        >
          {deleteSuccess}
        </div>
      ) : null}

      <div className="flex flex-col gap-6 lg:flex-row lg:items-start">
        <aside className="w-full shrink-0 rounded-xl border border-slate-200 bg-white p-4 shadow-sm lg:w-72">
          <h2 className="text-sm font-semibold text-slate-900">Remuneration plans</h2>
          <label className="mt-3 block text-xs font-medium text-slate-600" htmlFor="rem-plan-search">
            Search plans
          </label>
          <input
            id="rem-plan-search"
            type="search"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Filter by name…"
            autoComplete="off"
            className="mt-1 w-full rounded-md border border-slate-300 px-2 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
          />
          <button
            type="button"
            onClick={() => void createMut.mutateAsync()}
            disabled={createMut.isPending}
            className="mt-3 w-full rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:opacity-50"
          >
            {createMut.isPending ? 'Creating…' : 'Create new plan'}
          </button>
          {createMut.isError ? (
            <p className="mt-2 text-xs text-red-600">
              {createMut.error instanceof Error
                ? createMut.error.message
                : String(createMut.error)}
            </p>
          ) : null}
          <ul className="mt-4 max-h-[min(50vh,28rem)] space-y-1 overflow-y-auto">
            {filteredPlans.length === 0 ? (
              <li className="text-sm text-slate-500">No plans match your search.</li>
            ) : (
              filteredPlans.map((p) => {
                const cnt = staffCountForPlan(p, staffCounts)
                const active = p.id === selectedId
                return (
                  <li key={p.id}>
                    <button
                      type="button"
                      onClick={() => setSelectedId(p.id)}
                      className={`w-full rounded-lg border px-3 py-2.5 text-left text-sm transition ${
                        active
                          ? 'border-violet-300 bg-violet-50 text-violet-950'
                          : 'border-transparent bg-slate-50/80 text-slate-800 hover:border-slate-200 hover:bg-white'
                      }`}
                    >
                      <span className="font-medium">{p.plan_name}</span>
                      <span className="mt-0.5 block text-xs text-slate-500">
                        {cnt} staff linked
                      </span>
                    </button>
                  </li>
                )
              })
            )}
          </ul>
        </aside>

        <div className="min-w-0 flex-1">
          {!selected ? (
            <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
              <p className="text-sm text-slate-600">Select a plan to edit, or create one.</p>
            </section>
          ) : (
            <div className="flex flex-col gap-6 lg:flex-row lg:items-start">
              <div className="min-w-0 flex-1 space-y-6">
                <form
                  id="rem-plan-editor-form"
                  className="space-y-6 rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6"
                  onSubmit={(e) => {
                    e.preventDefault()
                    void saveMut.mutateAsync()
                  }}
                >
                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="plan-name">
                      Plan name
                    </label>
                    <input
                      id="plan-name"
                      value={draftName}
                      onChange={(e) => setDraftName(e.target.value)}
                      required
                      className="mt-1 w-full max-w-md rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>

                  <section className="space-y-4" aria-labelledby="rem-standard-heading">
                    <div>
                      <h2
                        id="rem-standard-heading"
                        className="text-base font-semibold text-slate-900"
                      >
                        Standard commission rates
                      </h2>
                      <p className="mt-1 text-sm text-slate-600">
                        Default rates for typical retail, professional product, and service
                        lines. Enter whole-number percentages (0–100); each is multiplied by
                        the ex GST line value when that classification applies.
                      </p>
                    </div>
                    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
                      {REMUNERATION_STANDARD_COMMISSION_CATEGORIES.map((cat) => (
                        <CommissionRateCard
                          key={cat}
                          cat={cat}
                          value={draftPercents[cat] ?? 0}
                          onChange={(next) =>
                            setDraftPercents((prev) => ({ ...prev, [cat]: next }))
                          }
                        />
                      ))}
                    </div>
                    <div className="rounded-xl border border-slate-200 bg-slate-50/90 p-4 shadow-sm">
                      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:gap-4">
                        <label className="flex w-fit shrink-0 cursor-pointer items-center gap-2 rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-800 shadow-sm">
                          <input
                            type="checkbox"
                            checked={draftAssistants}
                            onChange={(e) => setDraftAssistants(e.target.checked)}
                            className="rounded border-slate-300"
                          />
                          Allow assistants
                        </label>
                        <p className="min-w-0 flex-1 text-xs leading-relaxed text-slate-600">
                          {REMUNERATION_CAN_USE_ASSISTANTS_DESCRIPTION}
                        </p>
                      </div>
                    </div>
                  </section>

                  <section className="space-y-4 border-t border-slate-100 pt-6" aria-labelledby="rem-plan-specific-heading">
                    <div>
                      <h2
                        id="rem-plan-specific-heading"
                        className="text-base font-semibold text-slate-900"
                      >
                        Plan specific commission rates
                      </h2>
                      <p className="mt-2 text-sm leading-relaxed text-slate-600">
                        These are override rates that apply to specific products or services once
                        a line is classified into one of the categories below (for example,
                        toner or extensions, based on product headers). Commission is this
                        percentage times ex GST for matching lines.
                      </p>
                    </div>
                    <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
                      {REMUNERATION_PLAN_SPECIFIC_COMMISSION_CATEGORIES.map((cat) => (
                        <CommissionRateCard
                          key={cat}
                          cat={cat}
                          value={draftPercents[cat] ?? 0}
                          onChange={(next) =>
                            setDraftPercents((prev) => ({ ...prev, [cat]: next }))
                          }
                        />
                      ))}
                    </div>
                  </section>

                  <div>
                    <label className="block text-sm font-medium text-slate-700" htmlFor="conditions">
                      Notes / conditions
                    </label>
                    <textarea
                      id="conditions"
                      value={draftNotes}
                      onChange={(e) => setDraftNotes(e.target.value)}
                      rows={4}
                      placeholder="Optional conditions or internal notes for this plan…"
                      className="mt-1 w-full max-w-2xl rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
                    />
                  </div>
                </form>

                <div className="border-t border-slate-100 pt-6">
                  <h3 className="text-sm font-semibold text-slate-900">Delete plan</h3>
                  <div className="mt-3 flex flex-col gap-3 sm:flex-row sm:items-start">
                    <button
                      type="button"
                      disabled={!canDeletePlan || deleteMut.isPending}
                      onClick={() => {
                        if (!selected || !canDeletePlan) return
                        const ok = window.confirm(
                          `Delete remuneration plan "${selected.plan_name}" permanently? This cannot be undone.`,
                        )
                        if (!ok) return
                        void deleteMut.mutateAsync(selected.id)
                      }}
                      className="rounded-md border border-red-200 bg-white px-4 py-2 text-sm font-medium text-red-800 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-50"
                    >
                      {deleteMut.isPending ? 'Deleting…' : 'Delete plan'}
                    </button>
                    <p className="max-w-xl text-left text-sm text-slate-600">
                      {canDeletePlan ? (
                        <>
                          Permanently removes this plan and its category rates. Only available
                          when no staff use this plan.
                        </>
                      ) : (
                        <>
                          To delete a plan, all associated staff must first be moved to another
                          commission plan. Do this in the{' '}
                          <span className="font-medium text-slate-800">Staff Configuration</span>{' '}
                          page.
                        </>
                      )}
                    </p>
                  </div>
                  {deleteMut.isError ? (
                    <p className="mt-2 text-sm text-red-600">
                      {deleteMut.error instanceof Error
                        ? deleteMut.error.message
                        : String(deleteMut.error)}
                    </p>
                  ) : null}
                </div>
              </div>

              <aside
                className="w-full shrink-0 rounded-xl border border-slate-200 bg-slate-50/90 p-4 shadow-sm lg:sticky lg:top-4 lg:w-72 lg:self-start"
                aria-label="Linked staff and save"
              >
                <h3 className="text-sm font-semibold text-slate-900">Staff on this plan</h3>
                <p className="mt-1 text-left text-xs text-slate-500">
                  Read-only list from staff profiles where remuneration plan matches this
                  plan name (case-insensitive).
                </p>
                {staffQuery.isLoading ? (
                  <p className="mt-3 text-left text-sm text-slate-500">Loading staff…</p>
                ) : staffQuery.isError ? (
                  <p className="mt-3 text-left text-sm text-red-600">Could not load staff list.</p>
                ) : (staffQuery.data?.length ?? 0) === 0 ? (
                  <p className="mt-3 text-left text-sm text-slate-600">No staff linked to this plan.</p>
                ) : (
                  <div className="mt-3 overflow-x-auto rounded-md border border-slate-200 bg-white">
                    <table className="w-full border-collapse text-left text-sm">
                      <thead>
                        <tr className="border-b border-slate-200 bg-slate-50/80">
                          <th className="px-3 py-2 text-left text-xs font-semibold uppercase tracking-wide text-slate-600">
                            Full name
                          </th>
                          <th className="px-3 py-2 text-left text-xs font-semibold uppercase tracking-wide text-slate-600">
                            Status
                          </th>
                        </tr>
                      </thead>
                      <tbody>
                        {staffQuery.data!.map((s) => (
                          <tr key={s.staff_member_id} className="border-b border-slate-100 last:border-0">
                            <td className="px-3 py-2 text-left font-medium text-slate-900">
                              {s.full_name}
                            </td>
                            <td
                              className={`px-3 py-2 text-left ${
                                s.is_active ? 'text-emerald-700' : 'text-slate-400'
                              }`}
                            >
                              {s.is_active ? 'Active' : 'Inactive'}
                            </td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}

                <div className="mt-4 border-t border-slate-200 pt-4">
                  <button
                    type="submit"
                    form="rem-plan-editor-form"
                    disabled={saveMut.isPending || !dirty}
                    className="w-full rounded-md bg-violet-600 px-4 py-2.5 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
                  >
                    {saveMut.isPending ? 'Saving…' : 'Save changes'}
                  </button>
                  {saveMut.isError ? (
                    <p className="mt-2 text-left text-sm text-red-600">
                      {saveMut.error instanceof Error
                        ? saveMut.error.message
                        : String(saveMut.error)}
                    </p>
                  ) : null}
                </div>
              </aside>
            </div>
          )}
        </div>
      </div>
      </div>
    </div>
  )
}
