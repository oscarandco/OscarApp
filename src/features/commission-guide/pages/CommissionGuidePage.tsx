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
  type CommissionGuideEnvelope,
  type CommissionGuideExample,
  type CommissionGuideExclusion,
  type CommissionGuideRateCard,
  type CommissionGuideSpecialCase,
} from '@/features/commission-guide/types/commissionGuide'
import { formatCommissionRatePercent, formatNzd, formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'
import { fetchStaffMembers } from '@/lib/staffMembersApi'

function todayIso(): string {
  const d = new Date()
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  const day = String(d.getDate()).padStart(2, '0')
  return `${y}-${m}-${day}`
}

function formatDisplayValue(v: string | null | undefined): string {
  const s = (v ?? '').trim()
  return s === '' ? '—' : s
}

function formatFteValue(v: number | string | null | undefined): string {
  if (v == null || v === '') return '—'
  const n = typeof v === 'number' ? v : Number(v)
  if (!Number.isFinite(n)) return String(v)
  return n.toFixed(4).replace(/\.?0+$/, '')
}

/**
 * Friendly text for the "Your commission" cell on every classification
 * row. Never shows raw codes or "0%" wording.
 */
function yourCommissionText(row: CommissionGuideClassificationRow): {
  primary: string
  tone: 'earn' | 'none'
} {
  if (row.counts_for_commission) {
    if (row.rate_for_this_plan != null) {
      return {
        primary: formatCommissionRatePercent(row.rate_for_this_plan),
        tone: 'earn',
      }
    }
    return { primary: 'No commission on this plan', tone: 'none' }
  }
  return { primary: 'No commission', tone: 'none' }
}

function rateCardDisplay(card: CommissionGuideRateCard): {
  primary: string
  tone: 'earn' | 'none'
} {
  if (card.has_rate && card.rate != null) {
    return { primary: formatCommissionRatePercent(card.rate), tone: 'earn' }
  }
  if (card.category === 'service') {
    return { primary: 'No service commission on this plan', tone: 'none' }
  }
  return { primary: 'No commission on this plan', tone: 'none' }
}

/* ------------------------------------------------------------------------- */
/* Staff picker (admin/manager only)                                         */
/* ------------------------------------------------------------------------- */

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
    <div>
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
        <option value="">— Select staff —</option>
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

/* ------------------------------------------------------------------------- */
/* Your current setup                                                         */
/* ------------------------------------------------------------------------- */

function YourSetupSection({ env }: { env: CommissionGuideEnvelope }) {
  const s = env.staff
  const name = formatDisplayValue(s.display_name ?? s.full_name)
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">Your current setup</h2>
        <p className="mt-1 text-xs text-slate-600">
          What payroll uses for {name} as at {formatShortDate(env.as_of_date)}.
          {env.plan_summary.using_fallback_to_current_profile ? (
            <span className="ml-1 rounded bg-amber-50 px-1.5 py-0.5 text-amber-800">
              No effective-dated history on this date — showing the current profile.
            </span>
          ) : null}
        </p>
      </header>
      <dl className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
        <SetupItem label="Name" value={name} />
        <SetupItem label="Primary role" value={formatDisplayValue(s.primary_role)} />
        <SetupItem label="Employment type" value={formatDisplayValue(s.employment_type)} />
        <SetupItem label="Remuneration plan" value={formatDisplayValue(s.remuneration_plan)} />
        <SetupItem label="FTE" value={formatFteValue(s.fte)} />
        <SetupItem
          label="Primary location"
          value={formatDisplayValue(s.primary_location_name)}
        />
        {s.secondary_roles ? (
          <SetupItem
            label="Secondary roles"
            value={formatDisplayValue(s.secondary_roles)}
          />
        ) : null}
        {s.effective_start_date ? (
          <SetupItem
            label="Effective from"
            value={formatShortDate(s.effective_start_date)}
          />
        ) : null}
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

/* ------------------------------------------------------------------------- */
/* Plan summary + important notes                                            */
/* ------------------------------------------------------------------------- */

function PlanSummarySection({ env }: { env: CommissionGuideEnvelope }) {
  const { plan_summary } = env
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">
          {plan_summary.headline}
        </h2>
        <p className="mt-2 text-sm text-slate-800">{plan_summary.plain_english}</p>
      </header>
      {plan_summary.important_notes.length > 0 ? (
        <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
          {plan_summary.important_notes.map((n, i) => (
            <article
              key={`${n.heading}-${i}`}
              className="rounded-lg border border-slate-100 bg-slate-50/70 p-3"
            >
              <h3 className="text-sm font-semibold text-slate-900">{n.heading}</h3>
              <p className="mt-1 text-sm text-slate-700">{n.body}</p>
            </article>
          ))}
        </div>
      ) : null}
    </section>
  )
}

/* ------------------------------------------------------------------------- */
/* Rate cards                                                                 */
/* ------------------------------------------------------------------------- */

function RateCardsSection({ cards }: { cards: CommissionGuideRateCard[] }) {
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">Your rates</h2>
        <p className="mt-1 text-xs text-slate-600">
          The categories your current plan can pay commission on.
        </p>
      </header>
      <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-3">
        {cards.map((c) => {
          const display = rateCardDisplay(c)
          return (
            <div
              key={c.category}
              className={[
                'rounded-lg border p-3',
                display.tone === 'earn'
                  ? 'border-emerald-200 bg-emerald-50/40'
                  : 'border-slate-200 bg-slate-50',
              ].join(' ')}
            >
              <div className="flex items-baseline justify-between gap-2">
                <h3 className="text-sm font-semibold text-slate-900">{c.label}</h3>
                <span
                  className={[
                    'text-right text-sm font-semibold tabular-nums',
                    display.tone === 'earn' ? 'text-emerald-800' : 'text-slate-500',
                  ].join(' ')}
                >
                  {display.primary}
                </span>
              </div>
              <p className="mt-1.5 text-xs text-slate-600">{c.plain_english}</p>
            </div>
          )
        })}
      </div>
    </section>
  )
}

/* ------------------------------------------------------------------------- */
/* Things that can affect commission                                         */
/* ------------------------------------------------------------------------- */

function ThingsThatAffectCommissionSection({
  rules,
}: {
  rules: CommissionGuideSpecialCase[]
}) {
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">
          Things that can affect commission
        </h2>
        <p className="mt-1 text-xs text-slate-600">
          Rules that change how individual sale lines are paid, beyond the basic rates above.
        </p>
      </header>
      <ul className="mt-4 divide-y divide-slate-100">
        {rules.map((r) => (
          <li key={r.rule_key} className="py-2.5">
            <div className="text-sm font-medium text-slate-900">{r.label}</div>
            <p className="mt-0.5 text-sm text-slate-700">{r.plain_english}</p>
          </li>
        ))}
      </ul>
    </section>
  )
}

/* ------------------------------------------------------------------------- */
/* Product and service guide                                                 */
/* ------------------------------------------------------------------------- */

function ProductGuideSection({
  rows,
  canShowTechnical,
}: {
  rows: CommissionGuideClassificationRow[]
  canShowTechnical: boolean
}) {
  const [query, setQuery] = useState('')
  const [filter, setFilter] = useState<
    'all' | 'earning' | 'no_commission' | 'professional'
  >('all')
  const [showTechnical, setShowTechnical] = useState(false)

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase()
    return rows.filter((r) => {
      if (filter === 'earning' && !r.counts_for_commission) return false
      if (filter === 'no_commission' && r.counts_for_commission) return false
      if (filter === 'professional' && r.commission_category !== 'professional_product') {
        return false
      }
      if (q === '') return true
      const hay =
        `${r.product_or_category} ${howWeTreatItLabel(r.commission_category)} ${r.configured_product_type ?? ''} ${r.imported_type ?? ''}`.toLowerCase()
      return hay.includes(q)
    })
  }, [rows, query, filter])

  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">
          Product and service guide
        </h2>
        <p className="mt-1 text-xs text-slate-600">
          How each configured product or service is treated for your commission.
        </p>
      </header>

      <div className="mt-4 flex flex-wrap items-end gap-3">
        <div className="min-w-[14rem] flex-1">
          <label
            className="block text-xs font-medium text-slate-600"
            htmlFor="cg-classification-search"
          >
            Search
          </label>
          <input
            id="cg-classification-search"
            type="search"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Find a product or service…"
            className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
          />
        </div>
        <div className="w-full shrink-0 sm:w-56">
          <label
            className="block text-xs font-medium text-slate-600"
            htmlFor="cg-classification-filter"
          >
            Filter
          </label>
          <select
            id="cg-classification-filter"
            value={filter}
            onChange={(e) =>
              setFilter(
                e.target.value as 'all' | 'earning' | 'no_commission' | 'professional',
              )
            }
            className="mt-1.5 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500"
          >
            <option value="all">All items</option>
            <option value="earning">Earning commission</option>
            <option value="no_commission">No commission</option>
            <option value="professional">Treatment / professional products</option>
          </select>
        </div>
        {canShowTechnical ? (
          <label className="flex items-center gap-2 text-xs font-medium text-slate-600">
            <input
              type="checkbox"
              checked={showTechnical}
              onChange={(e) => setShowTechnical(e.target.checked)}
              className="rounded border-slate-300"
            />
            Show technical details
          </label>
        ) : null}
        <div className="text-xs text-slate-500">
          {filtered.length} of {rows.length} items
        </div>
      </div>

      <div className="mt-4 overflow-x-auto">
        <table className="min-w-full divide-y divide-slate-200">
          <thead className="bg-slate-50/80">
            <tr>
              <th
                scope="col"
                className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
              >
                Product or service
              </th>
              <th
                scope="col"
                className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
              >
                How Oscar &amp; Co treats it
              </th>
              <th
                scope="col"
                className="px-3 py-2 text-right text-[10px] font-semibold uppercase tracking-wide text-slate-500"
              >
                Your commission
              </th>
              <th
                scope="col"
                className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
              >
                Plain English explanation
              </th>
              {canShowTechnical && showTechnical ? (
                <>
                  <th
                    scope="col"
                    className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                  >
                    Imported type
                  </th>
                  <th
                    scope="col"
                    className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                  >
                    Configured product type
                  </th>
                  <th
                    scope="col"
                    className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500"
                  >
                    Internal category
                  </th>
                </>
              ) : null}
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {filtered.map((row, idx) => {
              const treat = howWeTreatItLabel(row.commission_category)
              const yc = yourCommissionText(row)
              return (
                <tr
                  key={`${row.product_or_category}-${idx}`}
                  className={row.counts_for_commission ? '' : 'bg-slate-50/40'}
                >
                  <td className="px-3 py-2 text-xs font-medium text-slate-900">
                    {row.product_or_category}
                  </td>
                  <td className="px-3 py-2 text-xs text-slate-800">
                    <span
                      className={[
                        'inline-flex rounded-md px-2 py-0.5 text-[11px] font-medium',
                        row.counts_for_commission
                          ? 'bg-emerald-100 text-emerald-800'
                          : 'bg-slate-200 text-slate-700',
                      ].join(' ')}
                    >
                      {treat}
                    </span>
                  </td>
                  <td
                    className={[
                      'px-3 py-2 text-right text-xs font-medium tabular-nums',
                      yc.tone === 'earn' ? 'text-emerald-800' : 'text-slate-500',
                    ].join(' ')}
                  >
                    {yc.primary}
                  </td>
                  <td className="px-3 py-2 text-xs text-slate-700">{row.plain_english}</td>
                  {canShowTechnical && showTechnical ? (
                    <>
                      <td className="px-3 py-2 text-xs text-slate-600">
                        {formatDisplayValue(row.imported_type)}
                      </td>
                      <td className="px-3 py-2 text-xs text-slate-600">
                        {formatDisplayValue(row.configured_product_type)}
                      </td>
                      <td className="px-3 py-2 text-[11px] text-slate-500">
                        <code className="rounded bg-slate-100 px-1.5 py-0.5">
                          {row.commission_category ?? '—'}
                        </code>
                      </td>
                    </>
                  ) : null}
                </tr>
              )
            })}
          </tbody>
        </table>
        {filtered.length === 0 ? (
          <p className="mt-4 text-sm text-slate-500">No items match the current filters.</p>
        ) : null}
      </div>
    </section>
  )
}

/* ------------------------------------------------------------------------- */
/* Items that do not earn commission                                         */
/* ------------------------------------------------------------------------- */

function NoCommissionSection({ rows }: { rows: CommissionGuideExclusion[] }) {
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">
          Items that do not earn commission
        </h2>
        <p className="mt-1 text-xs text-slate-600">
          Sale lines that fall into these groups don't earn commission, even if the
          payment method (e.g. voucher) is unusual.
        </p>
      </header>
      <div className="mt-4 overflow-x-auto">
        <table className="min-w-full divide-y divide-slate-200">
          <thead className="bg-slate-50/80">
            <tr>
              <th className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500">
                What it is
              </th>
              <th className="px-3 py-2 text-left text-[10px] font-semibold uppercase tracking-wide text-slate-500">
                Why no commission
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-slate-100">
            {rows.map((r) => (
              <tr key={`${r.label}-${r.commission_category}`}>
                <td className="px-3 py-2 text-xs font-medium text-slate-900">{r.label}</td>
                <td className="px-3 py-2 text-xs text-slate-700">{r.plain_english}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}

/* ------------------------------------------------------------------------- */
/* Examples                                                                   */
/* ------------------------------------------------------------------------- */

function ExamplesSection({ rows }: { rows: CommissionGuideExample[] }) {
  return (
    <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
      <header>
        <h2 className="text-base font-semibold text-slate-900">Examples</h2>
        <p className="mt-1 text-xs text-slate-600">
          Worked examples using your current plan rates.
        </p>
      </header>
      <ul className="mt-4 space-y-2.5">
        {rows.map((ex, i) => {
          const hasNumbers = ex.sale_ex_gst != null
          const earnsSomething = (ex.commission ?? 0) > 0
          const isNoCommission =
            ex.commission != null && ex.commission === 0
          return (
            <li
              key={i}
              className="rounded-lg border border-slate-100 bg-slate-50/60 p-3 text-sm text-slate-800"
            >
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <span className="font-medium text-slate-900">{ex.label}</span>
              </div>
              {hasNumbers ? (
                <div className="mt-1.5 flex flex-wrap items-baseline gap-x-4 gap-y-1 text-xs text-slate-700">
                  <span>
                    Sale ex&nbsp;GST{' '}
                    <span className="font-medium text-slate-900">
                      {formatNzd(ex.sale_ex_gst as number)}
                    </span>
                  </span>
                  {ex.rate != null ? (
                    <span>
                      Rate{' '}
                      <span className="font-medium text-slate-900">
                        {formatCommissionRatePercent(ex.rate)}
                      </span>
                    </span>
                  ) : null}
                  <span>
                    Commission{' '}
                    <span
                      className={[
                        'font-semibold',
                        earnsSomething
                          ? 'text-emerald-800'
                          : isNoCommission
                            ? 'text-slate-500'
                            : 'text-slate-900',
                      ].join(' ')}
                    >
                      {ex.commission == null
                        ? 'Depends on the sale'
                        : earnsSomething
                          ? formatNzd(ex.commission)
                          : 'No commission'}
                    </span>
                  </span>
                </div>
              ) : null}
              <p className="mt-1.5 text-sm text-slate-700">{ex.plain_english}</p>
            </li>
          )
        })}
      </ul>
    </section>
  )
}

/* ------------------------------------------------------------------------- */
/* Page                                                                       */
/* ------------------------------------------------------------------------- */

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
        description="A plain-English explanation of how your commission works at Oscar & Co — pulled live from your current setup."
      />

      <section className="rounded-xl border border-slate-200 bg-white p-4 shadow-sm sm:p-6">
        <div className="flex flex-wrap items-end gap-3">
          {isElevated ? (
            <div className="min-w-[16rem] flex-1">
              <StaffPicker
                selectedId={pickedStaffId ?? ownStaffId}
                onChange={setPickedStaffId}
              />
            </div>
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
          {!isElevated ? (
            <p className="text-xs text-slate-500">
              Showing your own guide. Ask a manager or admin if you need to compare
              another setup.
            </p>
          ) : null}
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
          message="Loading commission guide…"
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
          <RateCardsSection cards={data.rate_cards} />
          <ThingsThatAffectCommissionSection rules={data.special_cases} />
          <ProductGuideSection
            rows={data.classification_table}
            canShowTechnical={isElevated}
          />
          <NoCommissionSection rows={data.exclusions} />
          <ExamplesSection rows={data.examples} />
        </>
      ) : null}
    </div>
  )
}
