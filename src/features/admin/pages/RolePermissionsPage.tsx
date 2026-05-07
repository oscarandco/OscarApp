import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'

import { useAccessProfile } from '@/features/access/accessContext'
import { canManageStaffAccessMappings } from '@/features/access/accessPermissions'
import {
  mergeRolePagePermissionRows,
  PAGE_ACCESS_MATRIX,
  ROLE_KEYS,
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
  commission_breakdown: 'Sales summary',
  imports: 'Import sales data',
  staff: 'Staff',
  products: 'Products',
  quotes: 'Quotes',
  remuneration: 'Remuneration',
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
    pageIds: ['weekly_payroll', 'commission_breakdown', 'imports'],
  },
  {
    id: 'configuration',
    label: 'Configuration',
    pageIds: ['staff', 'products', 'quotes', 'remuneration', 'access', 'role_permissions'],
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

type PermissionRowRendererProps = {
  pageId: PageId
  matrix: EffectivePageMatrix
  canEdit: boolean
  pendingKey: string | null
  updateMut: {
    isPending: boolean
    mutate: (input: {
      pageId: PageId
      roleKey: RoleKey
      accessLevel: PageAccessLevel
    }) => void
  }
}

function PermissionMatrixRow(props: PermissionRowRendererProps) {
  const { pageId, matrix, canEdit, pendingKey, updateMut } = props

  return (
    <tr className="border-b border-slate-100 last:border-b-0">
      <td className="px-3 py-2 font-medium text-slate-900">{PAGE_FEATURE_LABELS[pageId]}</td>
      {ROLE_KEYS.map((roleKey) => {
        const cellKey = `${pageId}:${roleKey}`
        const value = matrix[pageId][roleKey]
        const opts = optionsForCell(pageId, roleKey)
        const locked = pageId === 'role_permissions' && roleKey === 'admin'
        const busy = pendingKey === cellKey && updateMut.isPending
        const disabled = !canEdit || locked || busy

        return (
          <td key={roleKey} className="px-2 py-1.5 align-middle">
            <label className="sr-only">
              {PAGE_FEATURE_LABELS[pageId]} — {roleKey}
            </label>
            <select
              className={[
                'w-full min-w-[6.5rem] rounded-md border px-2 py-1.5 text-sm shadow-sm focus:outline-none focus:ring-1',
                LEVEL_SELECT_SURFACE[value],
                'disabled:cursor-not-allowed disabled:opacity-60',
              ].join(' ')}
              value={value}
              disabled={disabled}
              aria-busy={busy}
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
          </td>
        )
      })}
    </tr>
  )
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
      <div className="mx-auto max-w-6xl px-4 py-6">
        <PageHeader title="Role permissions" description="Configuration" />
        <LoadingState message="Loading permissions…" />
      </div>
    )
  }

  if (permQuery.isError) {
    return (
      <div className="mx-auto max-w-6xl px-4 py-6">
        <PageHeader title="Role permissions" description="Configuration" />
        <ErrorState
          title="Could not load permissions"
          error={permQuery.error}
          onRetry={() => void permQuery.refetch()}
        />
      </div>
    )
  }

  return (
    <div className="mx-auto max-w-6xl px-4 py-6">
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

      <div className="mt-6 overflow-x-auto rounded-xl border border-slate-200 bg-white shadow-sm">
        <table className="w-full min-w-[640px] border-collapse text-left text-sm">
          <thead>
            <tr className="border-b border-slate-200 bg-slate-50/90">
              <th className="px-3 py-3 font-semibold text-slate-900">Page / feature</th>
              {ROLE_KEYS.map((rk) => (
                <th key={rk} className="px-2 py-3 text-center font-semibold capitalize text-slate-800">
                  {rk}
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
                  className={`px-3 pb-1 text-[11px] font-semibold uppercase tracking-wide text-slate-400 ${sectionIndex === 0 ? 'pt-3' : 'pt-4'}`}
                >
                  {section.label}
                </td>
              </tr>
              {section.pageIds.map((pageId) => (
                <PermissionMatrixRow
                  key={pageId}
                  pageId={pageId}
                  matrix={matrix}
                  canEdit={canEdit}
                  pendingKey={pendingKey}
                  updateMut={updateMut}
                />
              ))}
            </tbody>
          ))}
        </table>
      </div>

    </div>
  )
}
