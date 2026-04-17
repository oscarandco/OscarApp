import {
  quoteInputTypeLabel,
  quotePricingTypeLabel,
  quoteRoleLabel,
  sortRolesCanonical,
  type QuoteService,
} from '@/features/admin/types/quoteConfiguration'

type QuoteServicesTableProps = {
  services: QuoteService[]
  onEdit: (svc: QuoteService) => void
  onDuplicate: (svc: QuoteService) => void
  onMove: (id: string, dir: 'up' | 'down') => void
  onToggleActive: (svc: QuoteService) => void
  onDelete: (svc: QuoteService) => void
}

const thBase =
  'border-b border-slate-200 px-3 py-2.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-4 sm:py-3 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700'
const tdBase =
  'whitespace-nowrap px-3 py-2.5 text-sm text-slate-700 sm:px-4 sm:py-3 align-top'

const actionBtnBase =
  'inline-flex items-center rounded-md border px-2 py-1 text-xs font-medium shadow-sm transition focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-1 disabled:cursor-not-allowed disabled:opacity-40'
const actionBtnNeutral = `${actionBtnBase} border-slate-200 bg-white text-slate-700 hover:bg-slate-50 focus-visible:ring-violet-500`
const actionBtnPrimary = `${actionBtnBase} border-violet-200 bg-violet-50 text-violet-800 hover:bg-violet-100 focus-visible:ring-violet-500`
const actionBtnDanger = `${actionBtnBase} border-rose-200 bg-white text-rose-700 hover:bg-rose-50 focus-visible:ring-rose-500`

export function QuoteServicesTable({
  services,
  onEdit,
  onDuplicate,
  onMove,
  onToggleActive,
  onDelete,
}: QuoteServicesTableProps) {
  const rows = [...services].sort((a, b) => a.displayOrder - b.displayOrder)

  if (rows.length === 0) {
    return (
      <div
        className="rounded-lg border border-dashed border-slate-200 bg-white px-6 py-12 text-center"
        data-testid="quote-services-empty"
      >
        <p className="text-sm font-medium text-slate-800">
          No services in this section yet.
        </p>
        <p className="mt-1 text-sm text-slate-600">
          Use <span className="font-medium">Add Service</span> above to create the first one.
        </p>
      </div>
    )
  }

  return (
    <div
      className="overflow-x-auto rounded-lg border border-slate-200 bg-white shadow-sm"
      data-testid="quote-services-table"
    >
      <table className="min-w-full divide-y divide-slate-200">
        <thead className="bg-slate-50">
          <tr>
            <th className={`${thBase} w-16`}>Order</th>
            <th className={thBase}>Service Name</th>
            <th className={thBase}>Input Type</th>
            <th className={thBase}>Pricing Type</th>
            <th className={thBase}>Visible Roles</th>
            <th className={`${thBase} w-28`}>Active</th>
            <th className={`${thBase} w-32`}>Used In Quotes</th>
            <th className={`${thBase} w-[26rem]`}>Actions</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((svc, idx) => {
            const canDelete = !svc.usedInSavedQuotes
            const canMoveUp = idx > 0
            const canMoveDown = idx < rows.length - 1
            return (
              <tr
                key={svc.id}
                className="hover:bg-slate-50"
                data-testid={`quote-services-row-${svc.id}`}
              >
                <td className={`${tdBase} tabular-nums`}>{svc.displayOrder}</td>
                <td className={tdBase}>
                  <div className="flex flex-col">
                    <span className="font-medium text-slate-900">{svc.name}</span>
                    {svc.internalKey ? (
                      <span className="font-mono text-xs text-slate-500">
                        {svc.internalKey}
                      </span>
                    ) : null}
                  </div>
                </td>
                <td className={tdBase}>
                  <TypeChip label={quoteInputTypeLabel(svc.inputType)} />
                </td>
                <td className={tdBase}>
                  <TypeChip label={quotePricingTypeLabel(svc.pricingType)} />
                </td>
                <td className={tdBase}>
                  {svc.visibleRoles.length === 0 ? (
                    <span className="text-xs text-slate-400">—</span>
                  ) : (
                    <div className="flex flex-wrap gap-1">
                      {sortRolesCanonical(svc.visibleRoles).map((r) => (
                        <span
                          key={r}
                          className="inline-flex items-center rounded-full bg-violet-50 px-2 py-0.5 text-[11px] font-medium text-violet-700 ring-1 ring-violet-200"
                        >
                          {quoteRoleLabel(r)}
                        </span>
                      ))}
                    </div>
                  )}
                </td>
                <td className={tdBase}>
                  {svc.active ? (
                    <span className="inline-flex items-center rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-medium text-emerald-700 ring-1 ring-emerald-200">
                      Active
                    </span>
                  ) : (
                    <span className="inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600 ring-1 ring-slate-200">
                      Archived
                    </span>
                  )}
                </td>
                <td className={tdBase}>
                  {svc.usedInSavedQuotes ? (
                    <span className="inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700 ring-1 ring-slate-200">
                      Yes
                    </span>
                  ) : (
                    <span className="inline-flex items-center rounded-full bg-slate-50 px-2 py-0.5 text-xs text-slate-500 ring-1 ring-slate-100">
                      No
                    </span>
                  )}
                </td>
                <td className={tdBase}>
                  <div className="flex flex-wrap items-center gap-1.5">
                    <button
                      type="button"
                      onClick={() => onEdit(svc)}
                      className={actionBtnPrimary}
                      data-testid={`quote-services-edit-${svc.id}`}
                    >
                      Edit
                    </button>
                    <button
                      type="button"
                      onClick={() => onDuplicate(svc)}
                      className={actionBtnNeutral}
                    >
                      Duplicate
                    </button>
                    <button
                      type="button"
                      onClick={() => onMove(svc.id, 'up')}
                      disabled={!canMoveUp}
                      className={actionBtnNeutral}
                      title={canMoveUp ? 'Move up' : 'Already at the top'}
                      aria-label="Move service up"
                    >
                      ↑
                    </button>
                    <button
                      type="button"
                      onClick={() => onMove(svc.id, 'down')}
                      disabled={!canMoveDown}
                      className={actionBtnNeutral}
                      title={canMoveDown ? 'Move down' : 'Already at the bottom'}
                      aria-label="Move service down"
                    >
                      ↓
                    </button>
                    <button
                      type="button"
                      onClick={() => onToggleActive(svc)}
                      className={actionBtnNeutral}
                    >
                      {svc.active ? 'Archive' : 'Unarchive'}
                    </button>
                    <button
                      type="button"
                      onClick={() => onDelete(svc)}
                      disabled={!canDelete}
                      title={
                        canDelete
                          ? 'Delete service'
                          : 'Service has been used in saved quotes and cannot be deleted.'
                      }
                      className={actionBtnDanger}
                    >
                      Delete
                    </button>
                  </div>
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}

function TypeChip({ label }: { label: string }) {
  return (
    <span className="inline-flex items-center rounded-md bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700 ring-1 ring-slate-200">
      {label}
    </span>
  )
}
