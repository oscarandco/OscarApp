import { useQuery } from '@tanstack/react-query'
import { useMemo, useState } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useAccessProfile } from '@/features/access/accessContext'
import { useCommissionGuide } from '@/features/commission-guide/hooks/useCommissionGuide'
import {
  howWeTreatItLabel,
  type CommissionGuideClassificationRow,
  type CommissionGuideEligibleSection,
  type CommissionGuideEnvelope,
  type CommissionGuideNotEligibleSection,
  type CommissionGuideRecentItem,
} from '@/features/commission-guide/types/commissionGuide'
import { formatCommissionRatePercent, formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'
import { fetchStaffMembers } from '@/lib/staffMembersApi'

/* -------------------------------------------------------------------------- */
/* Helpers                                                                     */
/* -------------------------------------------------------------------------- */

function todayIso(): string {
  const d = new Date()
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

/** Friendly display for any string-ish value. Uses "Not set" instead of an em dash. */
function showOrNotSet(v: string | null | undefined): string {
  const s = (v ?? '').trim()
  return s === '' ? 'Not set' : s
}

function formatFteValue(v: number | string | null | undefined): string {
  if (v == null || v === '') return 'Not set'
  const n = typeof v === 'number' ? v : Number(v)
  if (!Number.isFinite(n)) return String(v)
  return n.toFixed(4).replace(/\.?0+$/, '')
}

/* -------------------------------------------------------------------------- */
/* Staff picker (admin / manager only)                                         */
/* -------------------------------------------------------------------------- */

function StaffPicker({
  selectedId,
  onChange,
}: {
  selectedId: string | null
  onChange: (id: string | null) => void
}) {
  const q = useQuery({
    queryKey: ['commission-guide-staff-picker'],
    queryFn: fetchStaffMembers,
    staleTime: 5 * 60_000,
  })

  const options = useMemo(() => {
    const rows = q.data ?? []
    return [...rows]
      .filter((s) => s.is_active)
      .sort((a, b) => {
        const ax = (a.display_name ?? a.full_name ?? '').toLowerCase()
        const bx = (b.display_name ?? b.full_name ?? '').toLowerCase()
        return ax.localeCompare(bx, undefined, { sensitivity: 'base' })
      })
  }, [q.data])

  return (
    <div className="min-w-[16rem] flex-1">
      <label
        className="block text-xs font-medium text-slate-600"
        htmlFor="commission-guide-staff-picker"
      >
        Staff member
      </label>
      <select
        id="commission-guide-staff-picker"
        value={selectedId ?? ''}
        onChange={(e) => onChange(e.target.value || null)}
        disabled={q.isLoading}
        className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500 disabled:bg-slate-50"
      >
        <option value="">Select staff</option>
        {options.map((s) => {
          const primary = (s.display_name ?? '').trim() || (s.full_name ?? '').trim() || 'Unnamed'
          const full = (s.full_name ?? '').trim()
          const disp = (s.display_name ?? '').trim()
          const showSecondary = disp && full && disp.toLowerCase() !== full.toLowerCase()
          return (
            <option key={s.id} value={s.id}>
              {primary}
              {showSecondary ? ` (${full})` : ''}
            </option>
          )
        })}
      </select>
      {q.isError ? (
        <p className="mt-1 text-xs text-red-600">Could not load staff list.</p>
      ) : null}
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/* Your current setup                                                          */
/* -------------------------------------------------------------------------- */

function YourSetupSection({ env }: { env: CommissionGuideEnvelope }) {
  const s = env.staff
  const name = showOrNotSet(s.display_name ?? s.full_name)
  const asOf = formatShortDate(env.as_of_date)
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">Your current setup</h2>
        <p className="mt-1 text-xs text-slate-600">
          What payroll uses for {name} on {asOf}.
          {env.plan_summary.using_fallback_to_current_profile ? (
            <span className="ml-1 rounded bg-amber-50 px-1.5 py-0.5 text-amber-800">
              No role and pay history on this date. Showing the current profile instead.
            </span>
          ) : null}
        </p>
      </header>
      <dl className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <SetupItem label="Name" value={name} />
        <SetupItem label="Primary role" value={showOrNotSet(s.primary_role)} />
        <SetupItem label="Employment type" value={showOrNotSet(s.employment_type)} />
        <SetupItem label="Remuneration plan" value={showOrNotSet(s.remuneration_plan)} />
        <SetupItem label="FTE" value={formatFteValue(s.fte)} />
        <SetupItem label="Primary location" value={showOrNotSet(s.primary_location_name)} />
        {s.secondary_roles ? (
          <SetupItem label="Secondary roles" value={showOrNotSet(s.secondary_roles)} />
        ) : null}
        {s.effective_start_date ? (
          <SetupItem
            label="Effective from"
            value={formatShortDate(s.effective_start_date)}
          />
        ) : null}
        <SetupItem label="Rules shown for" value={asOf} />
      </dl>
    </section>
  )
}

function SetupItem({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <dt className="text-xs font-medium uppercase tracking-wide text-slate-500">{label}</dt>
      <dd className="mt-0.5 text-sm text-slate-900">{value}</dd>
    </div>
  )
}

/* -------------------------------------------------------------------------- */
/* Plan summary                                                                */
/* -------------------------------------------------------------------------- */

function PlanSummarySection({ env }: { env: CommissionGuideEnvelope }) {
  const { plan_summary } = env
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">Plan summary</h2>
      </header>
      <p className="mt-2 text-sm text-slate-800">{plan_summary.plain_english}</p>
    </section>
  )
}

/* -------------------------------------------------------------------------- */
/* Eligible for commission                                                     */
/* -------------------------------------------------------------------------- */

function EligibleSectionsSection({
  sections,
}: {
  sections: CommissionGuideEligibleSection[]
}) {
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">Eligible for commission</h2>
        <p className="mt-1 text-xs text-slate-600">
          The categories your current plan pays you commission on.
        </p>
      </header>

      {sections.length === 0 ? (
        <p className="mt-4 rounded-lg border border-slate-100 bg-slate-50/70 p-3 text-sm text-slate-700">
          Your current plan does not pay commission on any category. See the
          {' '}
          <span className="font-medium">Not eligible for commission</span>
          {' '}
          section below for a quick explanation.
        </p>
      ) : (
        <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
          {sections.map((c) => (
            <article
              key={c.category}
              className="rounded-lg border border-emerald-200 bg-emerald-50/40 p-3"
            >
              <div className="flex items-baseline justify-between gap-2">
                <h3 className="text-sm font-semibold text-slate-900">{c.label}</h3>
                <span className="text-right text-sm font-semibold tabular-nums text-emerald-800">
                  {formatCommissionRatePercent(c.rate)}
                </span>
              </div>
              <p className="mt-1.5 text-xs text-slate-700">{c.summary}</p>
              {c.example ? (
                <p className="mt-1.5 rounded-md bg-white/70 px-2 py-1 text-xs text-slate-800">
                  <span className="font-medium text-slate-900">Example.</span>
                  {' '}
                  {c.example.plain_english}
                </p>
              ) : null}
            </article>
          ))}
        </div>
      )}
    </section>
  )
}

/* -------------------------------------------------------------------------- */
/* Not eligible for commission                                                 */
/* -------------------------------------------------------------------------- */

function NotEligibleSectionsSection({
  sections,
}: {
  sections: CommissionGuideNotEligibleSection[]
}) {
  if (sections.length === 0) return null
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">Not eligible for commission</h2>
        <p className="mt-1 text-xs text-slate-600">
          A short list of categories that don't earn you commission, with a one-line
          reason.
        </p>
      </header>
      <ul className="mt-4 space-y-2">
        {sections.map((r) => (
          <li
            key={r.category}
            className="rounded-lg border border-slate-100 bg-slate-50/60 p-3"
          >
            <div className="text-sm font-medium text-slate-900">{r.label}</div>
            <p className="mt-0.5 text-sm text-slate-700">{r.plain_english}</p>
          </li>
        ))}
      </ul>
    </section>
  )
}

/* -------------------------------------------------------------------------- */
/* Recent items to be aware of                                                 */
/* -------------------------------------------------------------------------- */

function RecentItemsSection({
  items,
  lookbackDays,
}: {
  items: CommissionGuideRecentItem[]
  lookbackDays: number
}) {
  if (items.length === 0) return null
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">Recent items to be aware of</h2>
        <p className="mt-1 text-xs text-slate-600">
          Items you've actually been involved in over the last {lookbackDays} days
          that have a special rule or no-commission treatment.
        </p>
      </header>
      <ul className="mt-4 space-y-2">
        {items.map((item, i) => (
          <li
            key={`${item.product_or_service}-${i}`}
            className="rounded-lg border border-slate-100 bg-slate-50/60 p-3"
          >
            <div className="flex flex-wrap items-baseline justify-between gap-2">
              <span className="text-sm font-medium text-slate-900">
                {item.product_or_service}
              </span>
              <span className="rounded-md bg-slate-200 px-2 py-0.5 text-[11px] font-medium text-slate-700">
                {item.treatment}
              </span>
            </div>
            <p className="mt-0.5 text-sm text-slate-700">{item.plain_english}</p>
            <p className="mt-0.5 text-[11px] text-slate-500">
              Seen {item.recent_line_count}{' '}
              {item.recent_line_count === 1 ? 'time' : 'times'} recently
              {item.last_seen ? `, most recent on ${formatShortDate(item.last_seen)}` : ''}.
            </p>
          </li>
        ))}
      </ul>
    </section>
  )
}

/* -------------------------------------------------------------------------- */
/* Admin only: full technical product guide (collapsed by default)             */
/* -------------------------------------------------------------------------- */

function AdminFullProductGuideSection({
  rows,
}: {
  rows: CommissionGuideClassificationRow[]
}) {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (q === '') return rows
    return rows.filter((r) => {
      const hay =
        `${r.product_or_category} ${howWeTreatItLabel(r.commission_category)} ${r.configured_product_type ?? ''} ${r.imported_type ?? ''}`.toLowerCase()
      return hay.includes(q)
    })
  }, [rows, query])

  return (
    <section className="rounded-xl border border-slate-200 bg-white shadow-sm">
      <button
        type="button"
        onClick={() => setOpen((x) => !x)}
        className="flex w-full items-center justify-between gap-4 px-4 py-3 text-left sm:px-6"
        aria-expanded={open}
      >
        <div>
          <h2 className="text-base font-semibold text-slate-900">
            Show full technical product guide
          </h2>
          <p className="mt-0.5 text-xs text-slate-600">
            Admin and manager only. The full list of configured products and how each
            one is treated. Collapsed by default.
          </p>
        </div>
        <span className="rounded-md border border-slate-200 px-2 py-1 text-xs font-medium text-slate-700">
          {open ? 'Hide' : 'Show'}
        </span>
      </button>

      {open ? (
        <div className="border-t border-slate-100 p-4 sm:p-6">
          <div className="mb-3 flex flex-wrap items-end gap-3">
            <div className="min-w-[14rem] flex-1">
              <label
                className="block text-xs font-medium text-slate-600"
                htmlFor="cg-admin-search"
              >
                Search
              </label>
              <input
                id="cg-admin-search"
                type="search"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Find a product or service..."
                className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
              />
            </div>
            <div className="text-xs text-slate-500">
              {filtered.length} of {rows.length} items
            </div>
          </div>
          <div className="overflow-x-auto">
            <table className="min-w-full divide-y divide-slate-200">
              <thead className="bg-slate-50/80">
                <tr>
                  <th className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500">
                    Product or service
                  </th>
                  <th className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500">
                    Treatment
                  </th>
                  <th className="px-3 py-2 text-right text-[10px] font-semibold uppercase tracking-wide text-slate-500">
                    Rate (this plan)
                  </th>
                  <th className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500">
                    Imported type
                  </th>
                  <th className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500">
                    Configured product type
                  </th>
                  <th className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500">
                    Internal category
                  </th>
                </tr>
              </thead>
              <tbody className="divide-y divide-slate-100">
                {filtered.map((row, idx) => {
                  const treat = howWeTreatItLabel(row.commission_category)
                  return (
                    <tr
                      key={`${row.product_or_category}-${idx}`}
                      className={row.counts_for_commission ? '' : 'bg-slate-50/40'}
                    >
                      <td className="px-3 py-2 text-xs font-medium text-slate-900">
                        {row.product_or_category}
                      </td>
                      <td className="px-3 py-2 text-xs text-slate-800">{treat}</td>
                      <td className="px-3 py-2 text-right text-xs tabular-nums text-slate-700">
                        {row.counts_for_commission && row.rate_for_this_plan != null
                          ? formatCommissionRatePercent(row.rate_for_this_plan)
                          : row.counts_for_commission
                            ? 'No commission on this plan'
                            : 'No commission'}
                      </td>
                      <td className="px-3 py-2 text-xs text-slate-600">
                        {showOrNotSet(row.imported_type)}
                      </td>
                      <td className="px-3 py-2 text-xs text-slate-600">
                        {showOrNotSet(row.configured_product_type)}
                      </td>
                      <td className="px-3 py-2 text-[11px] text-slate-500">
                        <code className="rounded bg-slate-100 px-1.5 py-0.5">
                          {row.commission_category ?? 'not classified'}
                        </code>
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
            {filtered.length === 0 ? (
              <p className="mt-4 text-sm text-slate-500">No items match your search.</p>
            ) : null}
          </div>
        </div>
      ) : null}
    </section>
  )
}

/* -------------------------------------------------------------------------- */
/* Page                                                                        */
/* -------------------------------------------------------------------------- */

export function CommissionGuidePage() {
  const { normalized } = useAccessProfile()
  const isElevated = Boolean(normalized?.hasElevatedAccess)
  const ownStaffId = normalized?.staffMemberId ?? null

  const [pickedStaffId, setPickedStaffId] = useState<string | null>(null)
  const [asOfDate, setAsOfDate] = useState<string>(todayIso())

  const targetStaffId = isElevated ? (pickedStaffId ?? ownStaffId) : ownStaffId

  const { data, isLoading, isError, error, refetch } = useCommissionGuide(
    targetStaffId,
    asOfDate,
  )

  return (
    <div className="mx-auto w-full max-w-7xl space-y-4 px-3 py-4 sm:px-6 sm:py-6">
      <PageHeader
        title="Commission Guide"
        description="A simple guide to what you can earn commission on."
      />

      <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
        <div className="flex flex-wrap items-end gap-3">
          {isElevated ? (
            <StaffPicker
              selectedId={pickedStaffId ?? ownStaffId}
              onChange={setPickedStaffId}
            />
          ) : null}
          <div className="w-full shrink-0 sm:w-48">
            <label
              className="block text-xs font-medium text-slate-600"
              htmlFor="commission-guide-as-of"
            >
              As at date
            </label>
            <input
              id="commission-guide-as-of"
              type="date"
              value={asOfDate}
              onChange={(e) => setAsOfDate(e.target.value || todayIso())}
              className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
            />
          </div>
        </div>
      </section>

      {!targetStaffId ? (
        <ErrorState
          title="No staff member to display"
          message="You don't have a staff mapping, and no staff member is selected."
          testId="commission-guide-no-target"
        />
      ) : isLoading ? (
        <LoadingState
          message="Loading commission guide..."
          testId="commission-guide-loading"
        />
      ) : isError ? (
        (() => {
          const detail = queryErrorDetail(error)
          return (
            <ErrorState
              title="Could not load commission guide"
              error={detail.err}
              message={detail.message}
              onRetry={() => void refetch()}
              testId="commission-guide-error"
            />
          )
        })()
      ) : data ? (
        <>
          <YourSetupSection env={data} />
          <PlanSummarySection env={data} />
          <EligibleSectionsSection sections={data.eligible_sections} />
          <NotEligibleSectionsSection sections={data.not_eligible_sections} />
          <RecentItemsSection
            items={data.recent_items_to_be_aware_of}
            lookbackDays={data.recent_lookback_days ?? 90}
          />
          {isElevated && data.admin_full_product_guide.length > 0 ? (
            <AdminFullProductGuideSection rows={data.admin_full_product_guide} />
          ) : null}
        </>
      ) : null}
    </div>
  )
}
