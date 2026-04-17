import { type MouseEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'

import type { QuoteSection } from '@/features/admin/types/quoteConfiguration'

type QuoteSectionsTableProps = {
  sections: QuoteSection[]
  serviceCounts: Record<string, number>
  onMove: (id: string, direction: 'up' | 'down') => void
  onToggleActive: (section: QuoteSection) => void
  onDelete: (section: QuoteSection) => void
}

const thBase =
  'border-b border-slate-200 px-2.5 py-1.5 text-left text-xs font-semibold uppercase tracking-wide text-slate-600 sm:px-3 sm:py-2 sm:normal-case sm:text-sm sm:tracking-normal sm:text-slate-700'
const tdBase =
  'whitespace-nowrap px-2.5 py-1.5 text-sm text-slate-700 sm:px-3 sm:py-2'

const actionBtnBase =
  'inline-flex items-center rounded-md border px-2 py-1 text-xs font-medium shadow-sm transition focus:outline-none focus-visible:ring-2 focus-visible:ring-offset-1 disabled:cursor-not-allowed disabled:opacity-40'
const actionBtnNeutral = `${actionBtnBase} border-slate-200 bg-white text-slate-700 hover:bg-slate-50 focus-visible:ring-violet-500`
const actionBtnPrimary = `${actionBtnBase} border-violet-200 bg-violet-50 text-violet-800 hover:bg-violet-100 focus-visible:ring-violet-500`
const actionBtnDanger = `${actionBtnBase} border-rose-200 bg-white text-rose-700 hover:bg-rose-50 focus-visible:ring-rose-500`

/**
 * Sections list. The full row is clickable to navigate into the section,
 * except when the click originates on an action button or link.
 */
export function QuoteSectionsTable({
  sections,
  serviceCounts,
  onMove,
  onToggleActive,
  onDelete,
}: QuoteSectionsTableProps) {
  const navigate = useNavigate()
  const rows = [...sections].sort((a, b) => a.displayOrder - b.displayOrder)

  if (rows.length === 0) {
    return (
      <div
        className="rounded-lg border border-dashed border-slate-200 bg-white px-6 py-12 text-center"
        data-testid="quote-sections-empty"
      >
        <p className="text-sm font-medium text-slate-800">No sections yet.</p>
        <p className="mt-1 text-sm text-slate-600">
          Use <span className="font-medium">Add Section</span> above to create the first one.
        </p>
      </div>
    )
  }

  function rowClickHandler(id: string) {
    return (e: MouseEvent<HTMLTableRowElement>) => {
      const target = e.target as HTMLElement
      if (target.closest('[data-row-action]')) return
      navigate(`/app/admin/quotes/sections/${id}`)
    }
  }

  return (
    <div
      className="overflow-x-auto rounded-lg border border-slate-200 bg-white shadow-sm"
      data-testid="quote-sections-table"
    >
      <table className="min-w-full divide-y divide-slate-200">
        <thead className="bg-slate-50">
          <tr>
            <th className={`${thBase} w-16`}>Order</th>
            <th className={thBase}>Section Name</th>
            <th className={thBase}>Summary Label</th>
            <th className={`${thBase} w-28`}>Active</th>
            <th className={`${thBase} w-24`}>Services</th>
            <th className={`${thBase} w-32`}>Used In Quotes</th>
            <th className={`${thBase} w-[24rem]`}>Actions</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((section, idx) => {
            const canMoveUp = idx > 0
            const canMoveDown = idx < rows.length - 1
            const canDelete = !section.usedInSavedQuotes
            return (
              <tr
                key={section.id}
                className="cursor-pointer transition hover:bg-slate-50 focus-within:bg-slate-50"
                onClick={rowClickHandler(section.id)}
                data-testid={`quote-sections-row-${section.id}`}
              >
                <td className={`${tdBase} tabular-nums`}>{section.displayOrder}</td>
                <td className={tdBase}>
                  <span className="font-medium text-slate-900">{section.name}</span>
                </td>
                <td className={tdBase}>
                  <span className="text-slate-700">{section.summaryLabel}</span>
                </td>
                <td className={tdBase}>
                  <ActiveBadge active={section.active} />
                </td>
                <td className={`${tdBase} tabular-nums`}>
                  {serviceCounts[section.id] ?? 0}
                </td>
                <td className={tdBase}>
                  <YesNoBadge value={section.usedInSavedQuotes} />
                </td>
                <td className={tdBase}>
                  <div
                    className="flex flex-wrap items-center gap-1.5"
                    data-row-action
                  >
                    <Link
                      to={`/app/admin/quotes/sections/${section.id}`}
                      className={actionBtnPrimary}
                      data-testid={`quote-sections-open-${section.id}`}
                    >
                      Open
                    </Link>
                    <button
                      type="button"
                      onClick={() => onMove(section.id, 'up')}
                      disabled={!canMoveUp}
                      className={actionBtnNeutral}
                      title={canMoveUp ? 'Move up' : 'Already at the top'}
                      aria-label="Move section up"
                    >
                      ↑
                    </button>
                    <button
                      type="button"
                      onClick={() => onMove(section.id, 'down')}
                      disabled={!canMoveDown}
                      className={actionBtnNeutral}
                      title={canMoveDown ? 'Move down' : 'Already at the bottom'}
                      aria-label="Move section down"
                    >
                      ↓
                    </button>
                    <button
                      type="button"
                      onClick={() => onToggleActive(section)}
                      className={actionBtnNeutral}
                    >
                      {section.active ? 'Archive' : 'Unarchive'}
                    </button>
                    <button
                      type="button"
                      onClick={() => onDelete(section)}
                      disabled={!canDelete}
                      title={
                        canDelete
                          ? 'Delete section'
                          : 'Section has been used in saved quotes and cannot be deleted.'
                      }
                      className={actionBtnDanger}
                      data-testid={`quote-sections-delete-${section.id}`}
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

function ActiveBadge({ active }: { active: boolean }) {
  if (active) {
    return (
      <span className="inline-flex items-center rounded-full bg-emerald-50 px-2 py-0.5 text-xs font-medium text-emerald-700 ring-1 ring-emerald-200">
        Active
      </span>
    )
  }
  return (
    <span className="inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-600 ring-1 ring-slate-200">
      Archived
    </span>
  )
}

function YesNoBadge({ value }: { value: boolean }) {
  if (value) {
    return (
      <span className="inline-flex items-center rounded-full bg-slate-100 px-2 py-0.5 text-xs font-medium text-slate-700 ring-1 ring-slate-200">
        Yes
      </span>
    )
  }
  return (
    <span className="inline-flex items-center rounded-full bg-slate-50 px-2 py-0.5 text-xs text-slate-500 ring-1 ring-slate-100">
      No
    </span>
  )
}
