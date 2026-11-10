import { useEffect, useRef } from 'react'
import { useQuery } from '@tanstack/react-query'
import { requireSupabaseClient } from '@/lib/supabase'
import { formatNzd, formatShortDate } from '@/lib/formatters'
import { useAuth } from '@/features/auth/authContext'
import { invoiceRateLabel, type InvoiceCalculationDetail, type InvoiceCalculationLine, type InvoiceMoney } from '../types/invoiceCalculation'

const money = (value: InvoiceMoney) => value == null ? 'Not recorded' : formatNzd(value)

export function ContractorSourceInvoiceDetail({ invoice, locationId, saleDate, staffMemberId, snapshot, onClose }: {
  invoice: string; locationId: string | null; saleDate: string | null; staffMemberId: string
  snapshot?: InvoiceCalculationDetail; onClose: () => void
}) {
  const dialog = useRef<HTMLDialogElement>(null)
  const { user } = useAuth()
  const query = useQuery({
    queryKey: ['contractor-source-calculation', user?.id, invoice, locationId, saleDate, staffMemberId],
    enabled: !snapshot,
    queryFn: async () => {
      const { data, error } = await requireSupabaseClient().rpc('get_contractor_source_invoice_calculation', {
        p_invoice: invoice, p_location_id: locationId, p_sale_date: saleDate, p_staff_member_id: staffMemberId,
      })
      if (error) throw new Error(error.message)
      return data as InvoiceCalculationDetail
    },
  })
  useEffect(() => { const element = dialog.current; element?.showModal(); return () => element?.close() }, [])
  const data = snapshot ?? query.data
  const first = data?.lines.find(l => l.eligible) ?? data?.lines[0]
  function people(line: InvoiceCalculationLine) {
    const ownerChanged = line.owner_name !== first?.owner_name
    const workerChanged = line.worker_name !== first?.worker_name
    const samePerson = ownerChanged && workerChanged && line.owner_name === line.worker_name
    return [line.sale_date !== first?.sale_date ? formatShortDate(line.sale_date) : '', samePerson ? `Staff: ${line.owner_name}` : ownerChanged ? `Owner: ${line.owner_name}` : '', !samePerson && workerChanged ? `Work: ${line.worker_name}` : ''].filter(Boolean).join(' · ')
  }
  const metrics = data ? [
    ['Customer invoice', data.customer_total_ex_gst], ['Eligible sales', data.eligible_sales_ex_gst],
    ['Product costs', data.product_cost_ex_gst], ['Commissionable', data.commissionable_ex_gst], ['Contractor fee', data.contractor_fee_ex_gst],
  ] as const : []
  return <dialog ref={dialog} aria-labelledby="contractor-calculation-title" onCancel={e => { e.preventDefault(); onClose() }}
    className="fixed inset-0 m-auto max-h-[92dvh] w-[calc(100%-1rem)] max-w-6xl overflow-y-auto rounded-xl border border-slate-200 bg-white p-3 shadow-xl backdrop:bg-black/40 sm:p-4">
    <header className="flex items-start justify-between gap-3 border-b border-slate-200 pb-3">
      <div className="min-w-0"><h2 id="contractor-calculation-title" className="break-words text-lg font-semibold">{invoice} · Commission detail</h2>
        <p className="mt-1 break-words text-xs text-slate-600">{formatShortDate(first?.sale_date ?? saleDate)} · {first?.customer_name ?? 'Customer'}{first ? first.owner_name === first.worker_name ? ` · Contractor: ${first.owner_name}` : ` · Owner: ${first.owner_name} · Work: ${first.worker_name}` : ''}</p>
        {snapshot ? <p className="mt-1 text-xs text-slate-500">Saved invoice calculation snapshot</p> : null}
      </div><button type="button" autoFocus onClick={onClose} className="min-h-11 shrink-0 rounded-md border border-slate-300 px-3 text-sm">Close</button>
    </header>
    {!snapshot && query.isPending ? <p role="status" className="py-5 text-sm">Loading calculation...</p> : null}
    {!snapshot && query.isError ? <div role="alert" className="py-4 text-sm text-red-700">{query.error.message} <button type="button" onClick={() => void query.refetch()} className="underline">Retry</button></div> : null}
    {data ? <>
      {!data.lines.length ? <p className="py-5 text-sm text-slate-600">No invoice lines found.</p> : <>
        <table className="mt-2 hidden w-full text-left text-xs sm:table"><thead className="border-b border-slate-200 text-slate-600"><tr>
          {['Product / service', 'Sales ex GST', 'Product cost', 'Commissionable', 'Rate', 'Contractor fee'].map(label => <th key={label} className={`px-2 py-2 font-medium ${label === 'Product / service' ? '' : 'text-right'}`}>{label}</th>)}
        </tr></thead><tbody>{data.lines.map(line => <tr key={line.id} className="border-b border-slate-100 align-top">
          <td className="px-2 py-2"><p className="font-medium">{line.product_service_name}</p><p className="mt-0.5 text-[11px] text-slate-500">{line.product_type_actual || (line.eligible ? 'Not classified' : 'Non-commission')}{!line.eligible ? ' · Excluded from contractor fee' : ''}</p>{people(line) ? <p className="mt-0.5 text-[11px] text-slate-500">{people(line)}</p> : null}</td>
          {[line.price_ex_gst, line.product_cost_ex_gst, line.commissionable_ex_gst].map((amount, i) => <td key={i} className="whitespace-nowrap px-2 py-2 text-right tabular-nums">{money(amount)}</td>)}
          <td className="whitespace-nowrap px-2 py-2 text-right">{line.eligible ? invoiceRateLabel(line.commission_rate) : 'Excluded'}</td><td className="whitespace-nowrap px-2 py-2 text-right font-medium tabular-nums">{formatNzd(line.contractor_fee_ex_gst)}</td>
        </tr>)}</tbody></table>
        <div className="divide-y divide-slate-200 sm:hidden">{data.lines.map(line => <article key={line.id} className="py-3">
          <h3 className="break-words text-sm font-medium">{line.product_service_name}</h3><p className="mt-0.5 break-words text-xs text-slate-500">{line.product_type_actual || (line.eligible ? 'Not classified' : 'Non-commission')}{!line.eligible ? ' · Excluded' : ''}{people(line) ? ` · ${people(line)}` : ''}</p>
          <dl className="mt-2 grid grid-cols-2 gap-x-3 gap-y-1.5 text-xs">{[['Sales ex GST', formatNzd(line.price_ex_gst)], ['Product cost', formatNzd(line.product_cost_ex_gst)], ['Commissionable', formatNzd(line.commissionable_ex_gst)], ['Rate', line.eligible ? invoiceRateLabel(line.commission_rate) : 'Excluded'], ['Contractor fee', formatNzd(line.contractor_fee_ex_gst)]].map(([label, value]) => <div key={label} className="flex min-w-0 flex-wrap justify-between gap-x-2 gap-y-0.5"><dt className="text-slate-600">{label}</dt><dd className="font-medium tabular-nums">{value}</dd></div>)}</dl>
        </article>)}</div>
      </>}
      <dl className="mt-3 grid grid-cols-2 gap-2 rounded-lg bg-slate-50 p-3 text-xs sm:grid-cols-5">{metrics.map(([label, value]) => <div key={label}><dt className="text-slate-600">{label} (ex GST)</dt><dd className="mt-1 font-semibold tabular-nums">{formatNzd(value)}</dd></div>)}</dl>
      <p className="mt-3 text-xs leading-relaxed text-slate-600">Product costs are deducted from eligible service sales before commission is calculated. Rates apply per item. Excluded lines are included in the customer invoice total but do not contribute to this contractor’s fee. The fee is rounded once per customer invoice.</p>
    </> : null}
  </dialog>
}
