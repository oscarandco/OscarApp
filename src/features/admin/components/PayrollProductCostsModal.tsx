import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useRef, useState, type FormEvent } from 'react'

import { usePageAccess } from '@/features/access/pageAccess'
import { formatShortDate } from '@/lib/formatters'
import { parseServiceCost, saveServiceProductCosts, type PayrollCostIssue } from '@/lib/serviceProductCostsApi'

export function PayrollProductCostsModal({ issues, onClose }: { issues: PayrollCostIssue[]; onClose: () => void }) {
  const canEdit = usePageAccess('service_product_costs') === 'full'
  const client = useQueryClient()
  const dialog = useRef<HTMLDivElement>(null)
  const [drafts, setDrafts] = useState<Record<string, { amount: string; date: string }>>({})
  const [error, setError] = useState<string | null>(null)
  const serviceCount = new Set(issues.map((issue) => issue.service_id ?? issue.service_name)).size
  const mutation = useMutation({
    mutationFn: saveServiceProductCosts,
    onSuccess: async () => {
      await client.invalidateQueries()
      onClose()
    },
  })
  useEffect(() => {
    const previous = document.activeElement
    dialog.current?.focus()
    const prevOverflow = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    return () => {
      document.body.style.overflow = prevOverflow
      if (previous instanceof HTMLElement) previous.focus()
    }
  }, [])

  function submit(event: FormEvent) {
    event.preventDefault()
    try {
      const entered = issues.filter((issue) => issue.reason === 'missing_cost' && issue.service_id && drafts[issue.issue_key]?.amount.trim())
      if (!entered.length) throw new Error('Enter at least one product cost, including an explicit 0 for a service with no product cost.')
      const costs = entered.map((issue) => {
        const draft = drafts[issue.issue_key]
        if (!draft.date) throw new Error('Choose an effective date for each entered cost.')
        return { service_id: issue.service_id!, unit_cost_ex_gst: parseServiceCost(draft.amount), effective_from: draft.date }
      })
      setError(null)
      mutation.mutate(costs)
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Check the entered product costs.') }
  }

  function setDraft(issue: PayrollCostIssue, field: 'amount' | 'date', value: string) {
    setDrafts((current) => ({ ...current, [issue.issue_key]: { ...(current[issue.issue_key] ?? { amount: '', date: issue.suggested_effective_from || issue.first_sale_date }), [field]: value } }))
  }

  return <div className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 p-4" onClick={() => { if (!mutation.isPending) onClose() }}>
    <div ref={dialog} tabIndex={-1} role="dialog" aria-modal="true" aria-labelledby="payroll-product-costs-title" data-testid="payroll-product-costs-modal" className="max-h-[90dvh] w-full max-w-4xl overflow-y-auto rounded-xl bg-white p-5 shadow-xl focus:outline-none" onClick={(e) => e.stopPropagation()} onKeyDown={(event) => {
      if (event.key === 'Escape' && !mutation.isPending) onClose()
      if (event.key === 'Tab') {
        const elements = dialog.current?.querySelectorAll<HTMLElement>('button:not(:disabled), input:not(:disabled), a[href]')
        if (!elements?.length) return
        const first = elements[0]
        const last = elements[elements.length - 1]
        if (event.shiftKey && (document.activeElement === first || document.activeElement === dialog.current)) { event.preventDefault(); last.focus() }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
      }
    }}>
      <div className="flex items-start justify-between gap-4"><h2 id="payroll-product-costs-title" className="text-lg font-semibold">{serviceCount} {serviceCount === 1 ? 'service needs' : 'services need'} product cost review</h2><button type="button" className="rounded-md border border-slate-300 px-3 py-1 text-sm" disabled={mutation.isPending} onClick={onClose}>Close</button></div>
      <p className="mt-2 text-sm text-slate-600">Commission is awaiting these settings for the selected week, across both salons. Enter costs per service unit excluding GST. Discounts do not reduce the cost. Closing this window leaves the commission unresolved.</p>
      {!canEdit ? <p className="mt-3 rounded-md bg-amber-50 p-3 text-sm text-amber-900">An admin with permission to manage service product costs must resolve these items before commission can be reviewed.</p> : null}
      <form onSubmit={submit}>
        <div className="my-4 space-y-3">{issues.map((issue) => {
          const editable = canEdit && issue.reason === 'missing_cost' && Boolean(issue.service_id)
          return <section key={issue.issue_key} className="rounded-lg border border-slate-200 p-3">
            <h3 className="text-sm font-semibold">{issue.service_name}</h3>
            <p className="mt-1 text-xs text-slate-600">{formatShortDate(issue.first_sale_date)}{issue.last_sale_date !== issue.first_sale_date ? ` – ${formatShortDate(issue.last_sale_date)}` : ''} · {issue.affected_units ?? 'Unknown'} affected units</p>
            {editable ? <div className="mt-3 flex flex-wrap gap-3">
              <label className="flex flex-col gap-1 text-sm">Product cost per unit ex GST<input aria-label={`Product cost for ${issue.service_name}`} type="number" step="0.01" min="0" value={drafts[issue.issue_key]?.amount ?? ''} disabled={mutation.isPending} onChange={(e) => setDraft(issue, 'amount', e.target.value)} placeholder="Enter cost, including 0" className="w-56 rounded-md border border-slate-300 px-3 py-2" /></label>
              <label className="flex flex-col gap-1 text-sm">Effective from<input aria-label={`Cost effective date for ${issue.service_name}`} type="date" value={drafts[issue.issue_key]?.date ?? (issue.suggested_effective_from || issue.first_sale_date)} disabled={mutation.isPending} onChange={(e) => setDraft(issue, 'date', e.target.value)} className="rounded-md border border-slate-300 px-3 py-2" /></label>
            </div> : <p className="mt-2 text-sm text-amber-900">{issue.reason === 'missing_cost' ? 'A dated product cost is required.' : `Review required: ${issue.reason.replaceAll('_', ' ')}. Correct the service mapping or source sale data; no quantity or cost will be guessed.`}</p>}
          </section>
        })}</div>
        {(error || mutation.error) ? <p role="alert" className="mb-3 rounded-md bg-red-50 p-3 text-sm text-red-800">{error ?? mutation.error?.message}</p> : null}
        <p className="mb-3 text-xs text-slate-500">Saving creates normal dated cost history shared by both salons and later weeks. The suggested date is the first affected sale date; confirm it before saving. Any remaining issues will still block commission.</p>
        {canEdit ? <button type="submit" className="rounded-md bg-violet-700 px-4 py-2 text-sm font-medium text-white disabled:opacity-50" disabled={mutation.isPending}>{mutation.isPending ? 'Saving and checking…' : 'Save costs and review commission'}</button> : null}
      </form>
    </div>
  </div>
}
