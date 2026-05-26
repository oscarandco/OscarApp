import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'

import { useAccessProfile } from '@/features/access/accessContext'
import { canManageStaffAccessMappings } from '@/features/access/accessPermissions'
import {
  mergeRolePagePermissionRows,
  PAGE_ACCESS_MATRIX,
  ROLE_DISPLAY_LABELS,
  ROLE_KEYS,
  roleColumnDividerClass,
  type EffectivePageMatrix,
  type PageAccessLevel,
  type PageId,
  type RoleKey,
} from '@/features/access/pageAccessMatrix'
import { useAuth } from '@/features/auth/authContext'
import { PageHeader } from '@/components/layout/PageHeader'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { queryErrorDetail } from '@/lib/queryError'
import { rpcGetRolePagePermissions, rpcUpdateRolePagePermission } from '@/lib/supabaseRpc'

const PAGE_FEATURE_LABELS: Record<PageId, string> = {
  my_payroll: 'My sales',
  guest_quote: 'Guest quote',
  previous_quotes: 'Previous quotes',
  kpi_dashboard: 'KPIs',
  weekly_payroll: 'Weekly payroll',
  contractor_invoices: 'Contractor invoices',
  commission_breakdown: 'Sales summary',
  imports: 'Import sales data',
  staff: 'Staff',
  products: 'Products',
  quotes: 'Quotes',
  remuneration: 'Remuneration',
  business_settings: 'Business settings',
  access: 'Access',
  role_permissions: 'Role permissions',
}

const LEVEL_LABELS: Record<PageAccessLevel, string> = {
  none: 'None',
  view: 'View',
  full: 'Full',
}

/** Selected-value styling (literal strings for Tailwind JIT). */
const LEVEL_SELECT_SURFACE: Record<PageAccessLevel, string> = {
  full: 'bg-red-50 border-red-200 text-red-800 focus:border-red-300 focus:ring-red-200',
  view: 'bg-amber-50 border-amber-200 text-amber-800 focus:border-amber-300 focus:ring-amber-200',
  none: 'bg-emerald-50 border-emerald-200 text-emerald-800 focus:border-emerald-300 focus:ring-emerald-200',
}

/** Mirrors sidebar structure: Main → Admin → Configuration. */
const PERMISSION_MATRIX_SECTIONS: { id: string; label: string; pageIds: PageId[] }[] = [
  {
    id: 'main',
    label: 'Main',
    pageIds: ['my_payroll', 'guest_quote', 'previous_quotes', 'kpi_dashboard'],
  },
  {
    id: 'admin',
    label: 'Admin',
    pageIds: [
      'weekly_payroll',
      'contractor_invoices',
      'commission_breakdown',
      'imports',
    ],
  },
  {
    id: 'configuration',
    label: 'Configuration',
    pageIds: [
      'staff',
      'products',
      'quotes',
      'remuneration',
      'business_settings',
      'access',
      'role_permissions',
    ],
  },
]

type FeedbackState =
  | { kind: 'success'; message: string }
  | { kind: 'error'; message: string }
  | null

function optionsForCell(pageId: PageId, roleKey: RoleKey): PageAccessLevel[] {
  if (pageId === 'role_permissions' && roleKey === 'admin') {
    return ['full']
  }
  if (pageId === 'access' && roleKey === 'admin') {
    return ['view', 'full']
  }
  return ['none', 'view', 'full']
}

type UpdateMutShape = {
  isPending: boolean
  mutate: (input: {
    pageId: PageId
    roleKey: RoleKey
    accessLevel: PageAccessLevel
  }) => void
}

type PermissionSelectProps = {
  pageId: PageId
  roleKey: RoleKey
  matrix: EffectivePageMatrix
  canEdit: boolean
  pendingKey: string | null
  updateMut: UpdateMutShape
}

function PermissionLevelSelect({
  pageId,
  roleKey,
  matrix,
  canEdit,
  pendingKey,
  updateMut,
}: PermissionSelectProps) {
  const cellKey = `${pageId}:${roleKey}`
  const value = matrix[pageId][roleKey]
  const opts = optionsForCell(pageId, roleKey)
  const locked = pageId === 'role_permissions' && roleKey === 'admin'
  const busy = pendingKey === cellKey && updateMut.isPending
  const disabled = !canEdit || locked || busy

  return (
    <select
      className={[
        'w-full min-w-0 max-w-full rounded-md border shadow-sm focus:outline-none focus:ring-1',
        'px-1 py-1 text-[11px] leading-tight md:px-2 md:py-1.5 md:text-sm md:leading-normal',
        LEVEL_SELECT_SURFACE[value],
        'disabled:cursor-not-allowed disabled:opacity-60',
      ].join(' ')}
      value={value}
      disabled={disabled}
      aria-busy={busy}
      aria-label={`${PAGE_FEATURE_LABELS[pageId]} — ${roleKey}`}
      onChange={(e) => {
        const next = e.target.value as PageAccessLevel
        if (next === value) return
        updateMut.mutate({
          pageId,
          roleKey,
          accessLevel: next,
        })
      }}
    >
      {opts.map((lvl) => (
        <option key={lvl} value={lvl}>
          {LEVEL_LABELS[lvl]}
        </option>
      ))}
    </select>
  )
}

type PermissionMatrixRowProps = {
  pageId: PageId
  matrix: EffectivePageMatrix
  canEdit: boolean
  pendingKey: string | null
  updateMut: UpdateMutShape
}

function PermissionMatrixRow(props: PermissionMatrixRowProps) {
  const { pageId, matrix, canEdit, pendingKey, updateMut } = props

  return (
    <tr className="border-b border-slate-100 last:border-b-0">
      <td className="max-w-[110px] px-1 py-1 align-middle text-[11px] font-medium leading-tight text-slate-900 md:max-w-none md:px-3 md:py-2 md:text-sm md:leading-normal">
        <span className="block truncate md:whitespace-normal">{PAGE_FEATURE_LABELS[pageId]}</span>
      </td>
      {ROLE_KEYS.map((roleKey) => (
        <td
          key={roleKey}
          className={`min-w-0 px-1 py-1 align-middle md:px-2 md:py-1.5 ${roleColumnDividerClass(roleKey)}`}
        >
          <PermissionLevelSelect
            pageId={pageId}
            roleKey={roleKey}
            matrix={matrix}
            canEdit={canEdit}
            pendingKey={pendingKey}
            updateMut={updateMut}
          />
        </td>
      ))}
    </tr>
  )
}

function pageShellClassName(): string {
  /** Align with other admin routes: full width of AppShell inner column (no mx-auto centre strip). */
  return 'w-full min-w-0 py-4 sm:py-6'
}

export function RolePermissionsPage() {
  const queryClient = useQueryClient()
  const { user } = useAuth()
  const { accessState, normalized } = useAccessProfile()
  const canEdit = canManageStaffAccessMappings(normalized)

  const [feedback, setFeedback] = useState<FeedbackState>(null)
  const [pendingKey, setPendingKey] = useState<string | null>(null)

  const permQuery = useQuery({
    queryKey: ['role-page-permissions', user?.id],
    queryFn: () => rpcGetRolePagePermissions(),
    enabled: Boolean(user) && accessState === 'ready',
  })

  const matrix = useMemo(() => {
    if (!permQuery.data) return PAGE_ACCESS_MATRIX
    return mergeRolePagePermissionRows(permQuery.data)
  }, [permQuery.data])

  const updateMut = useMutation({
    mutationFn: async (input: {
      pageId: PageId
      roleKey: RoleKey
      accessLevel: PageAccessLevel
    }) => {
      await rpcUpdateRolePagePermission({
        pageId: input.pageId,
        roleKey: input.roleKey,
        accessLevel: input.accessLevel,
      })
    },
    onMutate: async (vars) => {
      setPendingKey(`${vars.pageId}:${vars.roleKey}`)
      setFeedback(null)
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: ['role-page-permissions'] })
      setFeedback({
        kind: 'success',
        message: 'Permission updated.',
      })
    },
    onError: (err) => {
      const d = queryErrorDetail(err)
      setFeedback({
        kind: 'error',
        message: d.err?.message ?? d.message ?? 'Update failed.',
      })
    },
    onSettled: () => {
      setPendingKey(null)
    },
  })

  if (permQuery.isLoading || permQuery.isPending) {
    return (
      <div className={pageShellClassName()}>
        <PageHeader title="Role permissions" description="Configuration" />
        <LoadingState message="Loading permissions…" />
      </div>
    )
  }

  if (permQuery.isError) {
    return (
      <div className={pageShellClassName()}>
        <PageHeader title="Role permissions" description="Configuration" />
        <ErrorState
          title="Could not load permissions"
          error={permQuery.error}
          onRetry={() => void permQuery.refetch()}
        />
      </div>
    )
  }

  const rowProps = {
    matrix,
    canEdit,
    pendingKey,
    updateMut,
  }

  return (
    <div className={pageShellClassName()} data-testid="role-permissions-page">
      <PageHeader title="Role permissions" description="Configuration" />

      <p className="mt-2 max-w-3xl text-sm leading-relaxed text-slate-600">
        These settings control page visibility and route access. Changes apply to the sidebar and
        direct URL access.
      </p>

      {!canEdit ? (
        <p className="mt-3 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900">
          Only administrators can change role permissions. You can review the matrix below.
        </p>
      ) : null}

      {feedback ? (
        <div
          className={
            feedback.kind === 'success'
              ? 'mt-4 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-900'
              : 'mt-4 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-900'
          }
          role="status"
        >
          {feedback.message}
        </div>
      ) : null}

      {/* Single responsive matrix: compact on small screens, full spacing from md up */}
      <div className="mt-6 overflow-x-auto rounded-xl border border-slate-200 bg-white shadow-sm">
        <table className="w-full min-w-0 table-fixed border-collapse text-left">
          <colgroup>
            <col className="min-w-0 w-[18%] md:w-[22%]" />
            {ROLE_KEYS.map((rk) => (
              <col key={rk} className="min-w-0 w-[9.1%]" />
            ))}
          </colgroup>
          <thead>
            <tr className="border-b border-slate-200 bg-slate-50/90">
              <th className="px-1 py-2 text-left text-[10px] font-semibold leading-tight text-slate-900 md:px-3 md:py-3 md:text-sm">
                Page / feature
              </th>
              {ROLE_KEYS.map((rk) => (
                <th
                  key={rk}
                  className={`px-0.5 py-2 text-center text-[9px] font-semibold leading-tight text-slate-800 md:px-2 md:py-3 md:text-xs lg:text-sm ${roleColumnDividerClass(rk)}`}
                >
                  <span className="block truncate">{ROLE_DISPLAY_LABELS[rk]}</span>
                </th>
              ))}
            </tr>
          </thead>
          {PERMISSION_MATRIX_SECTIONS.map((section, sectionIndex) => (
            <tbody key={section.id}>
              <tr
                className={
                  sectionIndex === 0
                    ? 'bg-slate-50/40'
                    : 'border-t border-slate-200 bg-slate-50/40'
                }
              >
                <td
                  colSpan={1 + ROLE_KEYS.length}
                  className={`px-1 pb-0.5 text-[10px] font-semibold uppercase leading-tight tracking-wide text-slate-400 md:px-3 md:pb-1 md:text-[11px] ${sectionIndex === 0 ? 'pt-2 md:pt-3' : 'pt-3 md:pt-4'}`}
                >
                  {section.label}
                </td>
              </tr>
              {section.pageIds.map((pageId) => (
                <PermissionMatrixRow key={pageId} pageId={pageId} {...rowProps} />
              ))}
            </tbody>
          ))}
        </table>
      </div>
    </div>
  )
}
