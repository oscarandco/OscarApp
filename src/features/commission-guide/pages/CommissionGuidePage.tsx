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
  type CommissionGuideSectionExample,
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

/** Friendly display for any string-ish value. */
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

/** Always two-decimal money, e.g. $120.00 or $36.52. */
function formatMoney2(v: number | string | null | undefined): string {
  if (v == null || v === '') return '$0.00'
  const n = typeof v === 'number' ? v : Number(v)
  if (!Number.isFinite(n)) return '$0.00'
  return `$${n.toFixed(2)}`
}

/** Stable display order for eligible cards. */
const CATEGORY_ORDER: Record<string, number> = {
  service: 0,
  retail_product: 1,
  professional_product: 2,
  toner_with_other_service: 3,
  extensions_product: 4,
  extensions_service: 5,
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
/* What you can earn commission on                                             */
/* -------------------------------------------------------------------------- */

/**
 * Build the one-line example string from a real sale line.
 * Format:
 *   "{product_service_name} ${incl} including GST: ${excl} excluding GST @ {rate}% = ${commission} commission"
 */
function formatExampleSentence(ex: CommissionGuideSectionExample): string {
  const incl = formatMoney2(ex.price_incl_gst)
  const excl = formatMoney2(ex.price_ex_gst)
  const rate = formatCommissionRatePercent(ex.rate)
  const commission = formatMoney2(ex.commission)
  return `${ex.product_service_name} ${incl} including GST: ${excl} excluding GST @ ${rate} = ${commission} commission`
}

function EligibleCard({ section }: { section: CommissionGuideEligibleSection }) {
  const ex = section.example
  return (
    <article className="flex h-full flex-col rounded-lg border border-emerald-200 bg-emerald-50/40 p-3">
      <div className="flex items-baseline gap-2">
        <span className="text-base font-semibold tabular-nums text-emerald-800">
          {formatCommissionRatePercent(section.rate)}
        </span>
        <span aria-hidden="true" className="text-slate-400">
          -
        </span>
        <span className="text-base font-semibold text-slate-900">{section.label}</span>
      </div>
      {ex ? (
        <p className="mt-2 text-sm text-slate-800">
          <span className="font-medium text-slate-900">Example:</span>{' '}
          {formatExampleSentence(ex)}
        </p>
      ) : (
        <p className="mt-2 text-sm text-slate-500">Example: No recent example found.</p>
      )}
      {ex && !ex.is_staff_specific ? (
        <p className="mt-1 text-[11px] text-slate-500">Example from another staff member.</p>
      ) : null}
    </article>
  )
}

function WhatYouCanEarnSection({
  sections,
}: {
  sections: CommissionGuideEligibleSection[]
}) {
  const sorted = useMemo(() => {
    return [...sections].sort((a, b) => {
      const ai = CATEGORY_ORDER[String(a.category)] ?? 99
      const bi = CATEGORY_ORDER[String(b.category)] ?? 99
      if (ai !== bi) return ai - bi
      return String(a.label).localeCompare(String(b.label))
    })
  }, [sections])

  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">
          What you can earn commission on.
        </h2>
        <p className="mt-1 text-xs text-slate-600">
          All calculations are based on the price charged excluding GST.
        </p>
      </header>

      {sorted.length === 0 ? (
        <p className="mt-4 rounded-lg border border-slate-100 bg-slate-50/70 p-3 text-sm text-slate-700">
          Your current plan does not pay commission on any category.
        </p>
      ) : (
        <div className="mt-4 grid grid-cols-1 gap-3 lg:grid-cols-2">
          {sorted.map((c) => (
            <EligibleCard key={String(c.category)} section={c} />
          ))}
        </div>
      )}
    </section>
  )
}

/* -------------------------------------------------------------------------- */
/* What does not earn commission (static)                                      */
/* -------------------------------------------------------------------------- */

function WhatDoesNotEarnCommissionSection() {
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">What does not earn commission</h2>
        <p className="mt-1 text-xs text-slate-600">
          Commission is not paid on not-for-profit products and services, and items
          outside of your remuneration plan.
        </p>
      </header>
      <ul className="mt-3 list-disc space-y-1.5 pl-6 text-sm text-slate-800">
        <li>
          <span className="font-medium text-slate-900">Voucher sales:</span>{' '}
          No commission on sale of voucher, however commission is earned when a voucher
          is used for payment.
        </li>
        <li>Coffee</li>
        <li>Green Fees</li>
        <li>Training items</li>
        <li>Redos</li>
        <li>Miscellaneous line items not loaded as a product or service in the system.</li>
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
                    Rate on this plan
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
          <WhatYouCanEarnSection sections={data.eligible_sections} />
          <WhatDoesNotEarnCommissionSection />
          {isElevated && data.admin_full_product_guide.length > 0 ? (
            <AdminFullProductGuideSection rows={data.admin_full_product_guide} />
          ) : null}
        </>
      ) : null}
    </div>
  )
}
