import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { usePageAccess } from '@/features/access/pageAccess'
import { staffCountForPlan, useRemunerationConfiguration } from '@/features/admin/hooks/useRemunerationConfiguration'
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
  deleteRemunerationPlanIfUnused, duplicateRemunerationPlan,
  fetchStaffForRemunerationPlan, fetchTheoreticalBenchmarks, insertRemunerationPlan,
  saveRemunerationPlan, setRemunerationPlanActive, setTheoreticalBenchmark,
} from '@/lib/remunerationPlansApi'
import { queryErrorDetail } from '@/lib/queryError'
import { formatShortDate } from '@/lib/formatters'

const inputClass = 'mt-1 w-full rounded-md border border-slate-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500 disabled:bg-slate-100'
const buttonClass = 'rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50'

function ErrorMessage({ error }: { error: unknown }) {
  return error ? <p className="mt-2 text-sm text-red-700" role="alert">{error instanceof Error ? error.message : String(error)}</p> : null
}

function initialPercents(plan: RemunerationPlanWithRates): Record<RemunerationCommissionCategory, string> {
  return Object.fromEntries(REMUNERATION_COMMISSION_CATEGORIES.map((cat) => {
    const rate = Number(plan.rates.find((r) => r.commission_category === cat)?.rate ?? 0)
    return [cat, String(Math.round(rate * 10_000) / 100)]
  })) as Record<RemunerationCommissionCategory, string>
}

function BenchmarkHistory() {
  const schedule = useQuery({ queryKey: ['theoretical-benchmarks'], queryFn: fetchTheoreticalBenchmarks })
  return (
    <section className="mt-6 rounded-lg border border-slate-200 bg-white p-4" aria-labelledby="benchmark-heading" data-testid="theoretical-benchmark-schedule">
      <h2 id="benchmark-heading" className="text-sm font-semibold">Theoretical benchmark history</h2>
      <p className="mt-1 text-xs text-slate-600">Select the benchmark within a plan above. Each sale uses the benchmark effective on its sale date; earlier periods remain unchanged.</p>
      {schedule.isPending ? <p className="mt-3 text-sm">Loading benchmark schedule…</p> : null}
      <ErrorMessage error={schedule.error} />
      {schedule.data ? <div className="mt-3 overflow-x-auto"><table className="w-full text-left text-xs">
        <thead><tr className="border-b"><th className="px-2 py-1.5">Effective from</th><th className="px-2 py-1.5">Effective to</th><th className="px-2 py-1.5">Benchmark plan</th></tr></thead>
        <tbody>{schedule.data.map((row) => <tr key={row.id} className="border-b border-slate-100"><td className="whitespace-nowrap px-2 py-1.5">{row.effective_start_date === '0001-01-01' ? 'Reporting history' : formatShortDate(row.effective_start_date)}</td><td className="whitespace-nowrap px-2 py-1.5">{row.effective_end_date ? formatShortDate(row.effective_end_date) : 'Ongoing'}</td><td className="px-2 py-1.5 font-medium">{row.plan_name}</td></tr>)}</tbody>
      </table></div> : null}
    </section>
  )
}

function nextDate(date: string) {
  const next = new Date(`${date}T12:00:00Z`)
  next.setUTCDate(next.getUTCDate() + 1)
  return next.toISOString().slice(0, 10)
}

function BenchmarkConfirmation({ plan, minimumDate, pending, error, onConfirm, onClose }: {
  plan: RemunerationPlanWithRates
  minimumDate?: string
  pending: boolean
  error: unknown
  onConfirm: (date: string) => void
  onClose: () => void
}) {
  const now = new Date()
  const today = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`
  const [date, setDate] = useState(minimumDate && minimumDate > today ? minimumDate : today)
  const dialog = useRef<HTMLDivElement>(null)
  const dateInput = useRef<HTMLInputElement>(null)
  useEffect(() => {
    const previous = document.activeElement
    const returnTarget = previous instanceof HTMLElement ? previous.closest<HTMLElement>('[data-testid="plan-theoretical-benchmark-control"]') : null
    const overflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    dateInput.current?.focus()
    return () => {
      document.body.style.overflow = overflow
      if (previous instanceof HTMLElement && previous.isConnected) {
        if (previous.matches(':disabled')) returnTarget?.focus()
        else previous.focus()
      }
    }
  }, [])
  useEffect(() => { if (pending) dialog.current?.focus() }, [pending])
  const validDate = Boolean(date) && (!minimumDate || date >= minimumDate)
  return createPortal(<div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4" onClick={() => { if (!pending) onClose() }}>
    <div ref={dialog} tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby="benchmark-confirm-title" aria-describedby="benchmark-confirm-description" data-testid="theoretical-benchmark-confirmation" className="w-full max-w-lg rounded-xl bg-white p-5 shadow-xl focus:outline-none" onClick={(event) => event.stopPropagation()} onKeyDown={(event) => {
      if (event.key === 'Escape' && !pending) { event.stopPropagation(); onClose() }
      if (event.key === 'Tab') {
        const fields = dialog.current?.querySelectorAll<HTMLElement>('input:not(:disabled), button:not(:disabled)')
        if (!fields?.length) { event.preventDefault(); return }
        if (event.shiftKey && (document.activeElement === fields[0] || document.activeElement === dialog.current)) { event.preventDefault(); fields[fields.length - 1].focus() }
        else if (!event.shiftKey && document.activeElement === fields[fields.length - 1]) { event.preventDefault(); fields[0].focus() }
      }
    }}>
      <h2 id="benchmark-confirm-title" className="text-lg font-semibold">Use {plan.plan_name} for theoretical commission</h2>
      <p id="benchmark-confirm-description" className="mt-2 text-sm text-slate-600">From the date below, theoretical commission will use this plan’s rates, assistant settings and product-cost setting. Earlier dates retain their existing benchmark. Staff assignments are unchanged.</p>
      <label className="mt-4 block text-sm font-medium">Effective from<input ref={dateInput} type="date" required min={minimumDate} className={inputClass} value={date} onChange={(event) => setDate(event.target.value)} disabled={pending} /></label>
      {minimumDate ? <p className="mt-2 text-xs text-slate-500">Choose {formatShortDate(minimumDate)} or later. Existing benchmark periods cannot be overwritten.</p> : null}
      <ErrorMessage error={error} />
      <div className="mt-5 flex justify-end gap-3"><button type="button" className="rounded-md border border-slate-300 px-4 py-2 text-sm" disabled={pending} onClick={onClose}>Cancel</button><button type="button" className={buttonClass} disabled={pending || !validDate} onClick={() => onConfirm(date)}>{pending ? 'Saving…' : 'Use this plan from date'}</button></div>
    </div>
  </div>, document.body)
}

function PlanBenchmarkControl({ plan, disabled, unsaved }: { plan: RemunerationPlanWithRates; disabled: boolean; unsaved: boolean }) {
  const queryClient = useQueryClient()
  const canEdit = usePageAccess('remuneration') === 'full'
  const schedule = useQuery({ queryKey: ['theoretical-benchmarks'], queryFn: fetchTheoreticalBenchmarks })
  const ongoing = schedule.data?.filter((row) => row.effective_end_date == null).sort((a, b) => b.effective_start_date.localeCompare(a.effective_start_date))[0]
  const selected = ongoing?.plan_id === plan.id
  const historical = schedule.data?.find((row) => row.plan_id === plan.id && row.effective_end_date != null)
  const [confirming, setConfirming] = useState(false)
  const [saved, setSaved] = useState(false)
  const save = useMutation({
    mutationFn: (date: string) => setTheoreticalBenchmark(plan.id, date),
    onSuccess: async () => { await queryClient.invalidateQueries(); setConfirming(false); setSaved(true) },
  })
  const unavailable = !canEdit || !plan.is_active || disabled || unsaved || schedule.isPending || schedule.isError || schedule.isFetching || selected || save.isPending
  return <div tabIndex={-1} className="rounded-lg border border-violet-200 bg-violet-50 p-4 focus:outline-none" data-testid="plan-theoretical-benchmark-control">
    <label className="flex items-start gap-2 text-sm font-medium"><input type="checkbox" className="mt-1" checked={selected} disabled={unavailable} aria-describedby="plan-benchmark-description" data-testid="use-plan-theoretical-benchmark" onChange={() => { save.reset(); setSaved(false); setConfirming(true) }} />Use this plan for theoretical commission</label>
    <p id="plan-benchmark-description" className="mt-2 text-sm text-slate-600">The standard comparison uses this plan’s commission rates and product-cost setting, independently of each person’s actual plan.</p>
    {selected && ongoing ? <p className="mt-2 text-sm font-medium text-violet-950">Benchmark from {ongoing.effective_start_date === '0001-01-01' ? 'the start of reporting history' : formatShortDate(ongoing.effective_start_date)}. To replace it, select another plan and choose an effective date.</p> : historical ? <p className="mt-2 text-xs text-slate-600">Previously used through {formatShortDate(historical.effective_end_date!)}. Retained in benchmark history.</p> : null}
    {unsaved ? <p className="mt-2 text-xs text-slate-600">Save your plan changes before choosing it as the benchmark.</p> : !plan.is_active ? <p className="mt-2 text-xs text-slate-600">Archived plans cannot be selected as a new benchmark.</p> : null}
    {schedule.isPending ? <p className="mt-2 text-xs text-slate-500">Checking benchmark…</p> : null}
    <ErrorMessage error={schedule.error} />
    {saved ? <p role="status" className="mt-2 text-sm text-emerald-700">Theoretical benchmark saved. Earlier periods are retained.</p> : null}
    {confirming ? <BenchmarkConfirmation plan={plan} minimumDate={ongoing ? nextDate(ongoing.effective_start_date) : undefined} pending={save.isPending} error={save.error} onConfirm={(date) => save.mutate(date)} onClose={() => { if (!save.isPending) setConfirming(false) }} /> : null}
  </div>
}

function PlanEditor({ plan, onSelect }: { plan: RemunerationPlanWithRates; onSelect: (id: string | null) => void }) {
  const queryClient = useQueryClient()
  const canEdit = usePageAccess('remuneration') === 'full'
  const [name, setName] = useState(plan.plan_name)
  const [assistants, setAssistants] = useState(plan.can_use_assistants === true)
  const [deduct, setDeduct] = useState(plan.deduct_service_product_costs === true)
  const [notes, setNotes] = useState(plan.conditions_text ?? '')
  const [percents, setPercents] = useState(initialPercents(plan))
  const [copyName, setCopyName] = useState(`${plan.plan_name} copy`)
  const staff = useQuery({ queryKey: ['remuneration-plan-staff', plan.id], queryFn: () => fetchStaffForRemunerationPlan(plan.id) })
  const original = initialPercents(plan)
  const dirty = name.trim() !== plan.plan_name || assistants !== (plan.can_use_assistants === true) || deduct !== (plan.deduct_service_product_costs === true) || notes !== (plan.conditions_text ?? '') || REMUNERATION_COMMISSION_CATEGORIES.some((cat) => percents[cat] !== original[cat])
  const refresh = () => queryClient.invalidateQueries()
  const save = useMutation({
    mutationFn: async () => {
      const rates = Object.fromEntries(REMUNERATION_COMMISSION_CATEGORIES.map((cat) => {
        const value = Number(percents[cat])
        if (percents[cat].trim() === '' || !Number.isFinite(value) || value < 0 || value > 100) throw new Error('Every commission rate must be a number between 0 and 100.')
        return [cat, value / 100]
      })) as Record<RemunerationCommissionCategory, number>
      await saveRemunerationPlan({ id: plan.id, plan_name: name, can_use_assistants: assistants, deduct_service_product_costs: deduct, conditions_text: notes.trim() || null, rates })
    }, onSuccess: refresh,
  })
  const copy = useMutation({ mutationFn: () => duplicateRemunerationPlan(plan.id, copyName), onSuccess: async (id) => { await refresh(); onSelect(id) } })
  const archive = useMutation({ mutationFn: () => setRemunerationPlanActive(plan.id, !plan.is_active), onSuccess: refresh })
  const remove = useMutation({ mutationFn: () => deleteRemunerationPlanIfUnused(plan.id), onSuccess: async () => { await refresh(); onSelect(null) } })
  const busy = save.isPending || copy.isPending || archive.isPending || remove.isPending

  function rateCards(categories: readonly RemunerationCommissionCategory[]) {
    return <div className="grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-3">{categories.map((cat) => <div key={cat} className="rounded-xl border border-slate-200 bg-slate-50 p-4">
      <label htmlFor={`rem-rate-${cat}`} className="text-sm font-semibold">{REMUNERATION_CATEGORY_CARD_TITLE[cat]}</label>
      <div className="mt-2 flex items-center gap-2"><input id={`rem-rate-${cat}`} type="number" min={0} max={100} step="0.01" required className={inputClass} value={percents[cat]} onChange={(e) => setPercents((prev) => ({ ...prev, [cat]: e.target.value }))} /><span>%</span></div>
      <p className="mt-3 text-xs leading-relaxed text-slate-600">{REMUNERATION_CATEGORY_DESCRIPTION[cat]}</p>
    </div>)}</div>
  }

  return <div className="min-w-0 flex-1 space-y-6">
    <form className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6" onSubmit={(e) => { e.preventDefault(); save.mutate() }} data-testid="remuneration-plan-editor">
      {!plan.is_active ? <p role="status" className="mb-4 rounded bg-slate-100 p-3 text-sm">Archived. Retained for historical calculations and unavailable for new staff assignments.</p> : null}
      <fieldset disabled={!canEdit || !plan.is_active || busy} className="space-y-6 disabled:opacity-70">
        <label className="block max-w-lg text-sm font-medium">Plan name<input className={inputClass} required value={name} onChange={(e) => setName(e.target.value)} /></label>
        <section className="space-y-3"><h2 className="font-semibold">Standard commission rates</h2><p className="text-sm text-slate-600">Rates apply to the commissionable amount excluding GST, after any eligible service product-cost deduction.</p>{rateCards(REMUNERATION_STANDARD_COMMISSION_CATEGORIES)}</section>
        <div className="rounded-lg border border-slate-200 bg-slate-50 p-4">
          <label className="flex items-center gap-2 text-sm font-medium"><input type="checkbox" checked={assistants} onChange={(e) => setAssistants(e.target.checked)} />Allow assistants</label>
          <p className="mt-2 text-xs text-slate-600">{REMUNERATION_CAN_USE_ASSISTANTS_DESCRIPTION}</p>
        </div>
        <div className="rounded-lg border border-violet-200 bg-violet-50 p-4">
          <label className="flex items-start gap-2 text-sm font-medium"><input type="checkbox" className="mt-1" checked={deduct} onChange={(e) => setDeduct(e.target.checked)} data-testid="remuneration-deduct-product-costs" />Deduct service product costs before calculating commission</label>
          <p className="mt-2 text-sm text-slate-600">Commission on service sales is calculated after subtracting the configured product cost per unit from the sale amount excluding GST. Discounts reduce the sale amount but do not reduce the product cost. Commission on a positive sale cannot fall below zero; credit lines retain negative commission.</p>
        </div>
        <PlanBenchmarkControl plan={plan} disabled={busy} unsaved={dirty} />
        <section className="space-y-3"><h2 className="font-semibold">Plan specific commission rates</h2>{rateCards(REMUNERATION_PLAN_SPECIFIC_COMMISSION_CATEGORIES)}</section>
        <label className="block text-sm font-medium">Notes / conditions<textarea className={inputClass} rows={4} value={notes} onChange={(e) => setNotes(e.target.value)} /></label>
        <button type="submit" className={buttonClass} disabled={!dirty || busy}>{save.isPending ? 'Saving…' : 'Save changes'}</button>
      </fieldset>
      <ErrorMessage error={save.error} />
      <p className="mt-3 text-xs text-slate-500">Plans already used in sales or benchmark history have protected calculation settings. Duplicate the plan to introduce a new arrangement, then apply a dated staff change.</p>
    </form>
    <div className="grid gap-5 xl:grid-cols-2">
      <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm"><h2 className="font-semibold">Duplicate this plan</h2><p className="mt-2 text-sm text-slate-600">Copies every commission rate, assistant setting, notes and product-cost setting. The copy gets its own permanent identity.</p><form className="mt-3 space-y-3" onSubmit={(e) => { e.preventDefault(); copy.mutate() }}><label className="block text-sm font-medium">Name for duplicated plan<input className={inputClass} value={copyName} onChange={(e) => setCopyName(e.target.value)} required disabled={!canEdit || busy} /></label><button className={buttonClass} disabled={!canEdit || busy || !copyName.trim()}>{copy.isPending ? 'Duplicating…' : 'Duplicate plan'}</button></form><ErrorMessage error={copy.error} /></section>
      <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm"><h2 className="font-semibold">Plan availability</h2><p className="mt-2 text-sm text-slate-600">Archiving hides the plan from new assignments. Existing dated assignments and theoretical benchmarks continue to resolve to this plan.</p><button type="button" className={`${buttonClass} mt-4`} disabled={!canEdit || busy} onClick={() => archive.mutate()}>{archive.isPending ? 'Updating…' : plan.is_active ? 'Archive plan' : 'Restore plan'}</button><ErrorMessage error={archive.error} /><div className="mt-5 border-t pt-4"><button type="button" className="text-sm font-medium text-red-700 disabled:opacity-50" disabled={!canEdit || busy || (staff.data?.length ?? 0) > 0 || staff.isPending || staff.isError} onClick={() => { if (window.confirm(`Permanently delete unused plan “${plan.plan_name}”?`)) remove.mutate() }}>Delete unused plan</button><p className="mt-2 text-xs text-slate-500">Deletion is rejected when staff history, benchmarks or any current staff reference the plan. Archive used plans instead.</p><ErrorMessage error={remove.error} /></div></section>
    </div>
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm"><h2 className="font-semibold">Staff on this plan</h2><p className="mt-1 text-xs text-slate-500">Current staff profiles linked by permanent plan identity.</p>{staff.isPending ? <p className="mt-3 text-sm">Loading staff…</p> : null}<ErrorMessage error={staff.error} />{staff.data ? <ul className="mt-3 divide-y divide-slate-100">{staff.data.length === 0 ? <li className="py-2 text-sm text-slate-500">No current staff linked.</li> : staff.data.map((s) => <li className="flex justify-between gap-4 py-2 text-sm" key={s.staff_member_id}><span>{s.full_name}</span><span className={s.is_active ? 'text-emerald-700' : 'text-slate-500'}>{s.is_active ? 'Active' : 'Inactive'}</span></li>)}</ul> : null}</section>
  </div>
}

export function RemunerationConfigurationPage() {
  const queryClient = useQueryClient()
  const canEdit = usePageAccess('remuneration') === 'full'
  const query = useRemunerationConfiguration()
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [newName, setNewName] = useState('')
  const plans = query.data?.plans ?? []
  const selected = plans.find((p) => p.id === selectedId) ?? plans[0] ?? null
  const create = useMutation({ mutationFn: () => insertRemunerationPlan({ planName: newName }), onSuccess: async (id) => { await queryClient.invalidateQueries(); setSelectedId(id); setNewName('') } })
  if (query.isPending) return <LoadingState message="Loading remuneration plans…" />
  if (query.isError) { const detail = queryErrorDetail(query.error); return <ErrorState title="Could not load remuneration plans" message={detail.message} error={detail.err} onRetry={() => void query.refetch()} /> }
  return <div data-testid="remuneration-config-page" className="w-full pb-8">
    <PageHeader title="Remuneration Configuration" description="Manage commission plans, dated staff arrangements and the standard theoretical benchmark." />
    <p className="mb-6 rounded-lg border border-amber-200 bg-amber-50 p-3 text-sm text-amber-950">To change commission arrangements, duplicate the existing plan and assign staff to the new plan using an effective date in Staff Configuration. Renaming or archiving a plan preserves its historical identity.</p>
    <div className="flex flex-col items-start gap-6 lg:flex-row">
      <aside className="w-full shrink-0 rounded-xl border border-slate-200 bg-white p-4 shadow-sm lg:w-64">
        <h2 className="font-semibold">Remuneration plans</h2><label className="mt-3 block text-sm">Search plans<input type="search" className={inputClass} value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Filter by name…" /></label>
        <form className="mt-4 space-y-2" onSubmit={(e) => { e.preventDefault(); create.mutate() }}><label className="block text-sm">New plan name<input className={inputClass} value={newName} onChange={(e) => setNewName(e.target.value)} required disabled={!canEdit || create.isPending} /></label><button className={`${buttonClass} w-full`} disabled={!canEdit || create.isPending || !newName.trim()}>{create.isPending ? 'Creating…' : 'Create new plan'}</button></form><ErrorMessage error={create.error} />
        <ul className="mt-4 max-h-[50vh] space-y-1 overflow-y-auto">{plans.filter((p) => p.plan_name.toLowerCase().includes(search.toLowerCase().trim())).map((p) => <li key={p.id}><button type="button" onClick={() => setSelectedId(p.id)} className={`w-full rounded-lg border p-3 text-left text-sm ${selected?.id === p.id ? 'border-violet-300 bg-violet-50' : 'border-transparent bg-slate-50'}`}><span className="font-medium">{p.plan_name}</span><span className="mt-1 block text-xs text-slate-500">{p.is_active ? 'Active' : 'Archived'} · {staffCountForPlan(p, query.data?.staffCounts ?? [])} staff linked</span></button></li>)}</ul>
      </aside>
      {selected ? <PlanEditor key={`${selected.id}:${selected.updated_at}`} plan={selected} onSelect={setSelectedId} /> : <p className="p-4 text-sm">Create a plan to get started.</p>}
    </div>
    <BenchmarkHistory />
  </div>
}
