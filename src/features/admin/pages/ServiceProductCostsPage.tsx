import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react'

import { PageHeader } from '@/components/layout/PageHeader'
import { usePageAccess } from '@/features/access/pageAccess'
import { formatNzd, formatShortDate } from '@/lib/formatters'
import { nextColumnSortState, type ColumnSortState } from '@/lib/tableSort'
import { sortServiceProductCosts, type ServiceCostDraft, type ServiceCostSortKey } from '@/lib/serviceProductCostsSort'
import {
  createServiceProductCostService, getServiceProductCostHistory, getServiceProductCosts,
  localDateInputValue, parseServiceCost, saveServiceProductCosts, setServiceProductCostServiceActive,
  type ServiceProductCost,
} from '@/lib/serviceProductCostsApi'

const inputClass = 'rounded-md border border-slate-300 bg-white px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500 disabled:bg-slate-100'
const tableInputClass = 'h-7 min-w-0 rounded-md border border-slate-300 bg-white px-2 py-1 text-xs focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500 disabled:bg-slate-100'
const buttonClass = 'rounded-md bg-violet-700 px-4 py-2 text-sm font-medium text-white hover:bg-violet-800 disabled:opacity-50'
type CostDraft = ServiceCostDraft

function CostSaveBar({ changed, pending, saving }: { changed: number; pending: boolean; saving: boolean }) {
  return <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-slate-200 bg-white p-3 shadow-sm">
    <p className="text-sm text-slate-600">{changed} cost{changed === 1 ? '' : 's'} entered. All entered costs are saved together.</p>
    <button className={buttonClass} disabled={pending || changed === 0}>{saving ? 'Saving…' : 'Save product costs'}</button>
  </div>
}

function ServiceCostSortHeader({ label, columnKey, sort, onSort }: {
  label: string; columnKey: ServiceCostSortKey; sort: ColumnSortState; onSort: (next: ColumnSortState) => void
}) {
  const direction = sort?.key === columnKey ? sort.dir : null
  return <th scope="col" aria-sort={direction === 'asc' ? 'ascending' : direction === 'desc' ? 'descending' : 'none'} className="border-b border-slate-200 px-2 py-2 font-semibold">
    <button type="button" className="group inline-flex w-full items-center gap-1 rounded text-left hover:text-violet-800 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500" onClick={() => onSort(nextColumnSortState(sort, columnKey))}>
      <span className="shrink-0 text-[10px] text-slate-400" aria-hidden="true">{direction === 'asc' ? '▲' : direction === 'desc' ? '▼' : '↕'}</span>
      <span>{label}</span>
    </button>
  </th>
}

export function ServiceProductCostsPage() {
  const canEdit = usePageAccess('service_product_costs') === 'full'
  const client = useQueryClient()
  const [asOf, setAsOf] = useState(localDateInputValue)
  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState('active')
  const [sort, setSort] = useState<ColumnSortState>(null)
  const [newName, setNewName] = useState('')
  const [drafts, setDrafts] = useState<Record<string, CostDraft>>({})
  const [historyService, setHistoryService] = useState<ServiceProductCost | null>(null)
  const historyDialog = useRef<HTMLElement>(null)
  const [feedback, setFeedback] = useState<string | null>(null)
  const [formError, setFormError] = useState<string | null>(null)
  useEffect(() => {
    if (!historyService) return
    const previous = document.activeElement
    const overflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    historyDialog.current?.focus()
    return () => {
      document.body.style.overflow = overflow
      if (previous instanceof HTMLElement) previous.focus()
    }
  }, [historyService])
  const list = useQuery({ queryKey: ['service-product-costs', asOf], queryFn: () => getServiceProductCosts(asOf), enabled: Boolean(asOf) })
  const history = useQuery({
    queryKey: ['service-product-cost-history', historyService?.service_id],
    queryFn: () => getServiceProductCostHistory(historyService!.service_id), enabled: historyService != null,
  })
  const refresh = async () => { await client.invalidateQueries() }
  const save = useMutation({
    mutationFn: saveServiceProductCosts,
    onSuccess: async () => { setDrafts({}); setFeedback('Product costs saved. Reports will use the cost effective on each sale date.'); setFormError(null); await refresh() },
  })
  const add = useMutation({
    mutationFn: createServiceProductCostService,
    onSuccess: async () => { setNewName(''); setFeedback('Service added. Enter its product cost, including an explicit $0 where applicable.'); await refresh() },
  })
  const archive = useMutation({
    mutationFn: ({ id, active }: { id: string; active: boolean }) => setServiceProductCostServiceActive(id, active),
    onSuccess: async () => { setFeedback('Service status updated. Historical costs are retained.'); await refresh() },
  })
  const visible = useMemo(() => (list.data ?? []).filter((service) => {
    if (!service.service_name.toLowerCase().includes(search.trim().toLowerCase())) return false
    if (filter === 'archived') return !service.is_active
    if (filter !== 'all' && !service.is_active) return false
    if (filter === 'missing') return service.unit_cost_ex_gst == null
    if (filter === 'zero') return service.unit_cost_ex_gst != null && Number(service.unit_cost_ex_gst) === 0
    if (filter === 'configured') return service.unit_cost_ex_gst != null
    return true
  }), [list.data, search, filter])
  const sortedServices = useMemo(() => sortServiceProductCosts(visible, sort, drafts, asOf), [visible, sort, drafts, asOf])
  const showArchivedDate = filter === 'archived' || filter === 'all'
  const showCostInputs = canEdit && filter !== 'archived'
  const columns: { key: ServiceCostSortKey; label: string }[] = [
    { key: 'service_name', label: 'Service' },
    { key: 'classification_labels', label: 'Imported classification' },
    { key: 'unit_cost_ex_gst', label: 'Current unit cost ex GST' },
    { key: 'effective_from', label: 'Effective from' },
    { key: 'seen_in_sales', label: 'Seen in imported sales' },
    { key: 'last_sale_date', label: 'Last sale' },
    ...(showArchivedDate ? [{ key: 'archived_at' as const, label: 'Archived on' }] : []),
    ...(showCostInputs ? [{ key: 'draft_unit_cost' as const, label: 'New unit cost ex GST' }, { key: 'draft_effective_from' as const, label: 'New cost effective from' }] : []),
  ]
  const changed = Object.values(drafts).filter((draft) => draft.amount.trim() !== '').length
  const pending = save.isPending || add.isPending || archive.isPending
  const error = formError ?? save.error?.message ?? add.error?.message ?? archive.error?.message ?? list.error?.message

  function updateDraft(serviceId: string, field: keyof CostDraft, value: string) {
    setDrafts((current) => ({ ...current, [serviceId]: { ...(current[serviceId] ?? { amount: '', effectiveFrom: asOf }), [field]: value } }))
    setFeedback(null)
  }

  function submitCosts(event: FormEvent) {
    event.preventDefault()
    try {
      const costs = Object.entries(drafts).filter(([, draft]) => draft.amount.trim() !== '').map(([id, draft]) => {
        if (!draft.effectiveFrom) throw new Error('Choose an effective date for each entered cost.')
        return { service_id: id, unit_cost_ex_gst: parseServiceCost(draft.amount), effective_from: draft.effectiveFrom }
      })
      if (!costs.length) throw new Error('Enter at least one product cost to save.')
      setFormError(null)
      save.mutate(costs)
    } catch (cause) { setFormError(cause instanceof Error ? cause.message : 'Check the product costs.') }
  }

  return (
    <div className="w-full min-w-0 space-y-5" data-testid="service-product-costs-page">
      <PageHeader title="Service product costs" description="Manage the product cost deducted before service commission. Costs are per unit, excluding GST, and shared across both salons." />
      <div className="rounded-lg border border-slate-200 bg-white p-4 text-sm text-slate-600">
        Selling prices come from Sales Daily Sheets. Enter only the product cost here. A blank cost means unconfigured; enter $0 to confirm that a service has no product cost. Changes apply from the effective date and retain earlier cost history. Deductions and payroll cost alerts apply only to lines finally classified as Service. Catalogue names, including starred names, do not override Professional Product, Retail Product or non-commission classifications.
      </div>
      {!canEdit ? <p className="text-sm text-slate-600">You have view-only access to service product costs.</p> : null}
      <div className="flex flex-wrap items-end gap-3">
        <label className="flex min-w-60 flex-1 flex-col gap-1 text-sm">Search services<input className={inputClass} value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Service name" /></label>
        <label className="flex flex-col gap-1 text-sm">Status<select className={inputClass} value={filter} onChange={(e) => {
          const nextFilter = e.target.value
          setFilter(nextFilter)
          if ((!['archived', 'all'].includes(nextFilter) && sort?.key === 'archived_at') ||
            (nextFilter === 'archived' && ['draft_unit_cost', 'draft_effective_from'].includes(sort?.key ?? ''))) setSort(null)
        }}>
          <option value="active">Active services</option><option value="missing">Missing cost</option><option value="zero">Explicit $0</option><option value="configured">Configured</option><option value="archived">Archived</option><option value="all">All services</option>
        </select></label>
        <label className="flex flex-col gap-1 text-sm">Costs as at<input type="date" className={inputClass} value={asOf} onChange={(e) => setAsOf(e.target.value)} /></label>
        <button type="button" className="rounded-md border border-slate-300 px-3 py-2 text-sm" onClick={() => void refresh()}>Refresh services</button>
      </div>
      {canEdit ? <form className="flex flex-wrap items-end gap-3 rounded-lg border border-slate-200 bg-white p-4" onSubmit={(e) => { e.preventDefault(); if (newName.trim()) add.mutate(newName.trim()) }}>
        <label className="flex min-w-60 flex-1 flex-col gap-1 text-sm">Add a service before its first sale<input className={inputClass} required value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="Exact Kitomba service name" /></label>
        <button className={buttonClass} disabled={pending || !newName.trim()}>Add service</button>
      </form> : null}
      {error ? <p role="alert" className="rounded-md border border-red-200 bg-red-50 p-3 text-sm text-red-800">{error}</p> : null}
      {feedback ? <p role="status" className="rounded-md border border-emerald-200 bg-emerald-50 p-3 text-sm text-emerald-800">{feedback}</p> : null}
      {list.isLoading ? <p className="text-sm text-slate-600">Loading services…</p> : <form onSubmit={submitCosts} className="space-y-3">
        {canEdit && (showCostInputs || changed > 0) ? <CostSaveBar changed={changed} pending={pending} saving={save.isPending} /> : null}
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white">
          <table className="w-full min-w-[760px] border-collapse text-left text-xs">
            <thead className="bg-slate-50"><tr>{columns.map((column) => <ServiceCostSortHeader key={column.key} label={column.label} columnKey={column.key} sort={sort} onSort={setSort} />)}<th scope="col" className="border-b border-slate-200 px-2 py-2 font-semibold">Actions</th></tr></thead>
            <tbody className="whitespace-nowrap">{sortedServices.map((service) => <tr key={service.service_id} className="border-b border-slate-100 align-middle">
              <td className="px-2 py-1 font-medium">{service.service_name}{!service.is_active ? <span className="ml-2 text-[11px] font-normal text-slate-500">Archived</span> : null}</td>
              <td className="px-2 py-1 text-slate-600" title={service.classification_labels?.length ? undefined : 'Not yet classified in imported sales'}>{service.classification_labels?.length ? service.classification_labels.join(', ') : 'Not classified'}</td>
              <td className="px-2 py-1 tabular-nums">{service.unit_cost_ex_gst == null ? <span className="text-amber-800">Unconfigured</span> : formatNzd(service.unit_cost_ex_gst)}</td>
              <td className="px-2 py-1">{service.effective_from ? formatShortDate(service.effective_from) : '—'}</td>
              <td className="px-2 py-1">{service.seen_in_sales ? 'Yes' : 'No'}</td>
              <td className="px-2 py-1">{service.last_sale_date ? formatShortDate(service.last_sale_date) : '—'}</td>
              {showArchivedDate ? <td className="px-2 py-1" title={service.archived_at ? undefined : service.is_active ? undefined : 'This service was archived before archive dates were recorded.'}>{service.is_active ? '—' : service.archived_at ? formatShortDate(service.archived_at) : 'Not recorded'}</td> : null}
              {showCostInputs ? <><td className="px-2 py-1"><input aria-label={`New product cost for ${service.service_name}`} className={`${tableInputClass} w-24`} type="number" min="0" step="0.01" placeholder="e.g. 0.00" value={drafts[service.service_id]?.amount ?? ''} onChange={(e) => updateDraft(service.service_id, 'amount', e.target.value)} disabled={!service.is_active || pending} /></td><td className="px-2 py-1"><input aria-label={`Effective date for ${service.service_name}`} className={`${tableInputClass} w-32`} type="date" value={drafts[service.service_id]?.effectiveFrom ?? asOf} onChange={(e) => updateDraft(service.service_id, 'effectiveFrom', e.target.value)} disabled={!service.is_active || pending} /></td></> : null}
              <td className="px-2 py-1"><div className="inline-flex items-center gap-3"><button type="button" className="py-1 text-violet-700 hover:underline" onClick={() => setHistoryService(service)}>History</button>{canEdit ? <button type="button" className="py-1 text-slate-600 hover:underline" disabled={pending} onClick={() => archive.mutate({ id: service.service_id, active: !service.is_active })}>{service.is_active ? 'Archive' : 'Reactivate'}</button> : null}</div></td>
            </tr>)}</tbody>
          </table>
          {!visible.length ? <p className="p-5 text-sm text-slate-500">No services match these filters.</p> : null}
        </div>
        {canEdit && (showCostInputs || changed > 0) ? <CostSaveBar changed={changed} pending={pending} saving={save.isPending} /> : null}
      </form>}
      {historyService ? <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4" role="dialog" aria-modal="true" aria-labelledby="service-cost-history-title" onClick={() => setHistoryService(null)} onKeyDown={(e) => { if (e.key === 'Escape') setHistoryService(null) }}>
        <section ref={historyDialog} tabIndex={-1} className="max-h-[85dvh] w-full max-w-xl overflow-y-auto rounded-xl bg-white p-5 shadow-xl focus:outline-none" onClick={(e) => e.stopPropagation()} onKeyDown={(e) => { if (e.key === 'Tab') { e.preventDefault(); historyDialog.current?.querySelector<HTMLButtonElement>('button')?.focus() } }}>
          <div className="flex items-start justify-between gap-4"><h2 id="service-cost-history-title" className="text-lg font-semibold">Cost history: {historyService.service_name}</h2><button type="button" autoFocus className="rounded border px-2 py-1 text-sm" onClick={() => setHistoryService(null)}>Close</button></div>
          <p className="my-3 text-sm text-slate-600">Amounts are per unit, ex GST. Earlier versions are retained for historical commission calculations.</p>
          {history.isLoading ? <p>Loading history…</p> : history.isError ? <p role="alert" className="text-sm text-red-700">{history.error.message}</p> : history.data?.length ? <table className="w-full text-left text-sm"><thead><tr><th className="py-2">Effective from</th><th>Through</th><th className="text-right">Unit cost</th></tr></thead><tbody>{history.data.map((version) => <tr key={version.id} className="border-t border-slate-100"><td className="py-2">{formatShortDate(version.effective_from)}</td><td>{version.effective_to ? formatShortDate(version.effective_to) : 'Ongoing'}</td><td className="text-right tabular-nums">{formatNzd(version.unit_cost_ex_gst)}</td></tr>)}</tbody></table> : <p className="text-sm text-slate-500">No product cost has been configured.</p>}
        </section>
      </div> : null}
    </div>
  )
}
