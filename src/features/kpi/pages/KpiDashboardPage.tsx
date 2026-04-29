import { useEffect, useMemo, useState } from 'react'
import { useQuery } from '@tanstack/react-query'

import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useHasElevatedAccess, useAccessProfile } from '@/features/access/accessContext'
import { useStaffMemberSearch } from '@/features/admin/hooks/useAccessMappingSearch'
import { KpiCard } from '@/features/kpi/components/KpiCard'
import { KpiDetailPanel } from '@/features/kpi/components/KpiDetailPanel'
import { KpiDrilldownTable } from '@/features/kpi/components/KpiDrilldownTable'
import {
  KpiFiltersBar,
  type KpiFiltersValue,
} from '@/features/kpi/components/KpiFiltersBar'
import type {
  KpiSnapshotScope,
  KpiStylistComparisonRow,
} from '@/features/kpi/data/kpiApi'
import { useKpiSnapshot } from '@/features/kpi/hooks/useKpiSnapshot'
import { useKpiStylistComparisons } from '@/features/kpi/hooks/useKpiStylistComparisons'
import { useMyFte } from '@/features/kpi/hooks/useMyFte'
import { useStaffFteForKpiDisplay } from '@/features/kpi/hooks/useStaffFteForKpiDisplay'
import { kpiSortComparator } from '@/features/kpi/kpiLabels'
import { formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'
import { rpcListActiveLocationsForImport } from '@/lib/supabaseRpc'

/**
 * KPI dashboard — card grid + filters bar.
 *
 * Controls for this slice:
 *   - month picker (all roles)
 *   - scope select, location select, staff select (elevated only)
 * Non-elevated users are pinned to `scope='staff'`; the backend then
 * auto-resolves their own `staff_member_id` from `auth.uid()`.
 *
 * Scope rules mirror `private.kpi_resolve_scope` exactly:
 *   - business   : no id required
 *   - location   : `p_location_id` required
 *   - staff      : `p_staff_member_id` required for elevated callers;
 *                  NULL is fine for non-elevated callers (auto-resolve).
 * The `enabled` gate below prevents firing the RPC in the two cases
 * where it would certainly raise (elevated + location/staff without
 * a picked id).
 */
/**
 * KPIs hidden from the compact individual-staff card view (non-elevated
 * self/staff, and elevated admin/manager when scope is Staff with a
 * specific member selected). Display-only; snapshot RPCs unchanged.
 *
 * `new_client_retention_6m` / `new_client_retention_12m` were
 * previously hidden here while their math was being reworked; they
 * now follow the split-window rule (see migration
 * `20260501520000_kpi_new_client_retention_split_window_rule.sql`)
 * and are visible in self view again.
 */
const SELF_VIEW_HIDDEN_KPI_CODES: ReadonlySet<string> = new Set([
  'stylist_profitability',
])

function firstOfCurrentMonth(): string {
  const d = new Date()
  const y = d.getFullYear()
  const m = String(d.getMonth() + 1).padStart(2, '0')
  return `${y}-${m}-01`
}

function formatMonthLabel(isoFirstOfMonth: string): string {
  // "1 Mar 2026" → "Mar 2026". Used for the header when the user
  // picks a historical month (non-current).
  const d = new Date(`${isoFirstOfMonth}T12:00:00`)
  if (Number.isNaN(d.getTime())) return isoFirstOfMonth
  return d.toLocaleDateString(undefined, { month: 'short', year: 'numeric' })
}

export function KpiDashboardPage() {
  const elevated = useHasElevatedAccess()
  const { normalized } = useAccessProfile()

  const [filters, setFilters] = useState<KpiFiltersValue>(() => ({
    periodStart: firstOfCurrentMonth(),
    scope: 'business',
    locationId: '',
    staffMemberId: '',
  }))

  // Locations / staff lists only matter for elevated users. Gate both
  // queries on `elevated` so stylist/assistant don't fire unused RPCs.
  const { data: locations = [], isLoading: locationsLoading } = useQuery({
    queryKey: ['list-active-locations-import'],
    queryFn: rpcListActiveLocationsForImport,
    enabled: elevated,
  })
  const { data: staff = [], isLoading: staffLoading } = useStaffMemberSearch(
    '',
    elevated,
  )

  // Elevated users pick the scope in the UI. Non-elevated users are
  // pinned to 'staff' so the UI shape matches what
  // `private.kpi_resolve_scope` will accept — see
  // `useKpiSnapshot` for the locked-scope rationale.
  const effectiveScope: KpiSnapshotScope = elevated ? filters.scope : 'staff'

  const effectiveLocationId =
    effectiveScope === 'location' && filters.locationId
      ? filters.locationId
      : null

  const effectiveStaffId =
    effectiveScope === 'staff' && elevated && filters.staffMemberId
      ? filters.staffMemberId
      : null

  const snapshotEnabled =
    (effectiveScope !== 'location' || !!effectiveLocationId) &&
    (effectiveScope !== 'staff' || !elevated || !!effectiveStaffId)

  /** Staff scope with a concrete subject: self (non-elevated) or picked staff (elevated). */
  const isIndividualStaffKpiView =
    effectiveScope === 'staff' && (!elevated || !!effectiveStaffId)

  const { data, isLoading, isFetching, isError, error, refetch } =
    useKpiSnapshot({
      periodStart: filters.periodStart,
      scope: effectiveScope,
      locationId: effectiveLocationId,
      staffMemberId: effectiveStaffId,
      enabled: snapshotEnabled,
    })

  // Stylist comparison layer is staff/self-only. Gate strictly so we
  // never fire the RPC on business / location views (the backend
  // would just return zero rows, but skipping the round-trip keeps
  // the elevated-user dashboards quiet). The comparison query is
  // intentionally separate from the snapshot — comparison values are
  // additive UI metadata, not part of the locked KPI return shape.
  // Snapshot RPC still accepts null staff id for non-elevated callers
  // (backend resolves from auth.uid()). Comparison RPC must receive an
  // explicit staff_member_id for staff scope so PostgREST always sends a
  // JWT-backed request with the same cohort key as the UI, and we never
  // fire before `normalized.staffMemberId` exists.
  const comparisonStaffMemberId =
    effectiveScope === 'staff'
      ? elevated
        ? effectiveStaffId
        : (normalized?.staffMemberId ?? null)
      : null

  const comparisonsEnabled = snapshotEnabled && effectiveScope === 'staff'
  const comparisonsRpcEnabled =
    comparisonsEnabled &&
    Boolean(comparisonStaffMemberId) &&
    Boolean(filters.periodStart?.trim())

  const {
    data: comparisonPayload,
    isPending: comparisonsPending,
  } = useKpiStylistComparisons({
    periodStart: filters.periodStart,
    scope: effectiveScope,
    locationId: effectiveLocationId,
    staffMemberId: comparisonStaffMemberId,
    enabled: comparisonsRpcEnabled,
    includeComparisonLeaders: elevated && isIndividualStaffKpiView,
  })
  const comparisonRows = comparisonPayload?.rows
  const topStylistDisplayNameByKpi =
    comparisonPayload?.topStylistDisplayNameByKpi ?? {}
  const comparisonUnavailable =
    comparisonsRpcEnabled && !comparisonsPending && comparisonPayload?.unavailable

  const comparisonByKpiCode = useMemo(() => {
    const map = new Map<string, KpiStylistComparisonRow>()
    for (const r of comparisonRows ?? []) map.set(r.kpi_code, r)
    return map
  }, [comparisonRows])

  // FTE-based normalisation for individual staff KPI cards (same rules
  // in `KpiCard`: `NORMALISABLE_KPI_CODES` + 0 < fte < 1). Self view
  // uses logged-in user's FTE; admin/manager Staff → member uses that
  // member's FTE so headline / Raw / (NORMALISED) match self view.
  const selfFteEnabled =
    !elevated && effectiveScope === 'staff' && snapshotEnabled
  const { data: myFte } = useMyFte({ enabled: selfFteEnabled })

  const elevatedStaffSubjectFteEnabled =
    elevated &&
    effectiveScope === 'staff' &&
    snapshotEnabled &&
    Boolean(effectiveStaffId)

  const { data: viewedStaffFte } = useStaffFteForKpiDisplay({
    staffMemberId: effectiveStaffId,
    enabled: elevatedStaffSubjectFteEnabled,
  })

  const cardFte = selfFteEnabled
    ? (myFte ?? null)
    : elevatedStaffSubjectFteEnabled
      ? (viewedStaffFte ?? null)
      : null

  const sortedRows = useMemo(() => {
    const rows = data ?? []
    const sorted = [...rows].sort((a, b) =>
      kpiSortComparator(a.kpi_code, b.kpi_code),
    )
    // Hide stylist_profitability (and any future set members) on the
    // compact individual-staff card grid only.
    if (isIndividualStaffKpiView) {
      return sorted.filter((r) => !SELF_VIEW_HIDDEN_KPI_CODES.has(r.kpi_code))
    }
    return sorted
  }, [data, isIndividualStaffKpiView])

  const first = sortedRows[0]

  // Diagnostic detail-panel selection. Reset to the first tile after
  // load, and whenever a filter change produces a row set that no
  // longer contains the previously-selected KPI (e.g. different
  // scope / period returns a different KPI mix). Reusing the same
  // `kpi_code` across renders means the panel stays on the user's
  // pick when the same KPI is still in the new snapshot.
  const [selectedKpiCode, setSelectedKpiCode] = useState<string | null>(null)

  useEffect(() => {
    if (sortedRows.length === 0) {
      if (selectedKpiCode !== null) setSelectedKpiCode(null)
      return
    }
    const stillPresent = sortedRows.some(
      (r) => r.kpi_code === selectedKpiCode,
    )
    if (!stillPresent) {
      setSelectedKpiCode(sortedRows[0].kpi_code)
    }
  }, [sortedRows, selectedKpiCode])

  const selectedRow = useMemo(
    () =>
      sortedRows.find((r) => r.kpi_code === selectedKpiCode) ??
      sortedRows[0] ??
      null,
    [sortedRows, selectedKpiCode],
  )

  const periodLabel = first
    ? first.is_current_open_month
      ? `Month-to-date · through ${formatShortDate(first.mtd_through)}`
      : formatMonthLabel(first.period_start)
    : formatMonthLabel(filters.periodStart)

  const scopeLabel = useMemo(() => {
    if (!first) {
      // Snapshot hasn't resolved yet — label from the user's pick.
      switch (effectiveScope) {
        case 'business':
          return 'Business'
        case 'location':
          return 'Location'
        case 'staff':
          return elevated ? 'Staff' : 'Self'
      }
    }
    switch (first.scope_type) {
      case 'business':
        return 'Business'
      case 'location': {
        const name = locations.find((l) => l.id === first.location_id)?.name
        return name ? `Location · ${name}` : 'Location'
      }
      case 'staff': {
        const match = staff.find(
          (s) => s.staff_member_id === first.staff_member_id,
        )
        const name = match?.display_name?.trim() || match?.full_name?.trim()
        if (elevated) return name ? `Staff · ${name}` : 'Staff'
        return 'Self'
      }
      default:
        return null
    }
  }, [first, effectiveScope, elevated, locations, staff])

  const description = scopeLabel
    ? `${scopeLabel} · ${periodLabel}`
    : periodLabel

  const filtersBar = (
    <KpiFiltersBar
      value={filters}
      onChange={setFilters}
      elevated={elevated}
      locations={locations}
      locationsLoading={locationsLoading}
      staff={staff}
      staffLoading={staffLoading}
      disabled={isFetching}
    />
  )

  // "Pick a value" prompt for the two elevated-scope-with-no-id cases.
  // Shown instead of the loading spinner because we intentionally did
  // not fire the RPC yet.
  if (!snapshotEnabled) {
    const prompt =
      effectiveScope === 'location'
        ? 'Select a location to view KPIs.'
        : 'Select a staff member to view KPIs.'
    return (
      <>
        <PageHeader title="KPIs" description={description} />
        {filtersBar}
        <EmptyState
          title="Choose a filter"
          description={prompt}
          testId="kpi-dashboard-needs-filter"
        />
      </>
    )
  }

  if (isLoading) {
    return (
      <>
        <PageHeader title="KPIs" description={description} />
        {filtersBar}
        <LoadingState testId="kpi-dashboard-loading" />
      </>
    )
  }

  if (isError) {
    const detail = queryErrorDetail(error)
    return (
      <>
        <PageHeader title="KPIs" description={description} />
        {filtersBar}
        <ErrorState
          title="Could not load KPIs"
          message={detail.message}
          error={detail.err}
          onRetry={() => refetch()}
          testId="kpi-dashboard-error"
        />
      </>
    )
  }

  if (sortedRows.length === 0) {
    return (
      <>
        <PageHeader title="KPIs" description={description} />
        {filtersBar}
        <EmptyState
          title="No KPIs available"
          description="No KPI rows were returned for the current selection."
          testId="kpi-dashboard-empty"
        />
      </>
    )
  }

  return (
    <>
      <PageHeader title="KPIs" description={description} />
      {filtersBar}
      <div
        className={
          // Elevated business/location: two-column layout + detail panel.
          // Individual staff view (self or picked staff): same single
          // column as stylist/assistant — five cards wide at xl.
          elevated && !isIndividualStaffKpiView
            ? 'flex flex-col gap-4 lg:grid lg:items-start lg:gap-5 lg:grid-cols-[minmax(0,1fr)_22rem]'
            : 'flex flex-col gap-4'
        }
        data-testid="kpi-dashboard-layout"
      >
        {comparisonUnavailable ? (
          <p
            className="text-sm text-neutral-500 dark:text-neutral-400"
            data-testid="kpi-comparison-unavailable"
          >
            Comparison data unavailable.
          </p>
        ) : null}
        <div
          className={
            elevated && !isIndividualStaffKpiView
              ? 'grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-2 xl:grid-cols-3'
              : 'grid grid-cols-1 gap-3 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4 xl:grid-cols-5'
          }
          data-testid="kpi-dashboard-grid"
        >
          {sortedRows.map((row) => (
            <KpiCard
              key={row.kpi_code}
              row={row}
              selected={row.kpi_code === selectedRow?.kpi_code}
              onSelect={setSelectedKpiCode}
              useNamedTopComparisonStylist={
                elevated && isIndividualStaffKpiView
              }
              comparisonTopStylistDisplayName={
                elevated && isIndividualStaffKpiView
                  ? topStylistDisplayNameByKpi[row.kpi_code]
                  : undefined
              }
              comparison={
                effectiveScope === 'staff'
                  ? comparisonByKpiCode.get(row.kpi_code) ?? null
                  : null
              }
              fte={cardFte}
            />
          ))}
        </div>
        {elevated && selectedRow && !isIndividualStaffKpiView ? (
          <KpiDetailPanel row={selectedRow} />
        ) : null}
      </div>
      {selectedRow ? (
        <KpiDrilldownTable
          kpiCode={selectedRow.kpi_code}
          periodStart={filters.periodStart}
          scope={effectiveScope}
          locationId={effectiveLocationId}
          staffMemberId={effectiveStaffId}
          enabled={snapshotEnabled}
        />
      ) : null}
    </>
  )
}
