import { useQueryClient } from '@tanstack/react-query'
import { useState } from 'react'

import { AccessMappingFormModal } from '@/features/admin/components/AccessMappingFormModal'
import { InviteUserModal } from '@/features/admin/components/InviteUserModal'
import { useAdminAccessMappings } from '@/features/admin/hooks/useAdminAccessMappings'
import { useUpdateAccessMappingMutation } from '@/features/admin/hooks/useAccessMappingMutations'
import {
  accessRoleDisplayLabel,
  normalizeAccessRoleForForm,
  type AdminAccessMappingRow,
} from '@/features/admin/types/accessManagement'
import { canManageStaffAccessMappings } from '@/features/access/accessPermissions'
import { useAccessProfile } from '@/features/access/accessContext'
import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { formatShortDate } from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'
import { invokeInviteAccessUser } from '@/lib/inviteAccessUser'

export function AdminAccessManagementPage() {
  const queryClient = useQueryClient()
  const { normalized } = useAccessProfile()
  const canManage = canManageStaffAccessMappings(normalized)

  const { data, isLoading, isError, error, refetch } = useAdminAccessMappings()
  const updateMut = useUpdateAccessMappingMutation()

  const [modalMode, setModalMode] = useState<'create' | 'edit' | null>(null)
  const [editRow, setEditRow] = useState<AdminAccessMappingRow | null>(null)
  const [inviteOpen, setInviteOpen] = useState(false)

  function openCreate() {
    setEditRow(null)
    setModalMode('create')
  }

  function openEdit(row: AdminAccessMappingRow) {
    setEditRow(row)
    setModalMode('edit')
  }

  function closeModal() {
    setModalMode(null)
    setEditRow(null)
  }

  function toggleActive(row: AdminAccessMappingRow) {
    if (!canManage) return
    updateMut.mutate({
      mappingId: row.mapping_id,
      staffMemberId: row.staff_member_id,
      accessRole: normalizeAccessRoleForForm(row.access_role),
      isActive: !row.is_active,
    })
  }

  if (isLoading) {
    return (
      <div data-testid="admin-access-page">
        <LoadingState
          message="Loading access mappings…"
          testId="admin-access-loading"
        />
      </div>
    )
  }

  if (isError) {
    const { message, err } = queryErrorDetail(error)
    return (
      <div data-testid="admin-access-page">
        <ErrorState
          title="Could not load access mappings"
          error={err}
          message={message}
          onRetry={() => void refetch()}
          testId="admin-access-error"
        />
      </div>
    )
  }

  const rows = data ?? []

  return (
    <div data-testid="admin-access-page" className="max-w-[100vw]">
      <PageHeader
        title="Access management"
        description="Link Supabase accounts to staff members. Only admins can create or change mappings; managers can view this list."
      />

      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-slate-600">
          {rows.length} mapping{rows.length === 1 ? '' : 's'}
        </p>
        {canManage ? (
          <div className="flex flex-wrap gap-2">
            <button
              type="button"
              onClick={() => setInviteOpen(true)}
              className="rounded-md border border-violet-200 bg-white px-4 py-2 text-sm font-medium text-violet-800 hover:bg-violet-50"
              data-testid="admin-access-invite-user"
            >
              Invite user
            </button>
            <button
              type="button"
              onClick={openCreate}
              className="rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white hover:bg-violet-700"
              data-testid="admin-access-create"
            >
              Create mapping
            </button>
          </div>
        ) : null}
      </div>

      {updateMut.isError ? (
        <p className="mb-4 text-sm text-red-700">
          {updateMut.error instanceof Error
            ? updateMut.error.message
            : String(updateMut.error)}
        </p>
      ) : null}

      {rows.length === 0 ? (
        <EmptyState
          title="No access mappings"
          description="When you add mappings, they will appear here."
          testId="admin-access-empty"
        />
      ) : (
        <div className="overflow-x-auto rounded-lg border border-slate-200 bg-white shadow-sm">
          <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
            <thead className="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-600">
              <tr>
                <th className="px-3 py-3">Email</th>
                <th className="px-3 py-3">Staff</th>
                <th className="px-3 py-3">Role</th>
                <th className="px-3 py-3">Active</th>
                <th className="px-3 py-3">Updated</th>
                <th className="px-3 py-3 text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {rows.map((row) => (
                <tr
                  key={row.mapping_id}
                  className={
                    row.is_active ? 'bg-white' : 'bg-slate-50/80 text-slate-600'
                  }
                >
                  <td className="px-3 py-2 font-mono text-xs text-slate-900">
                    {row.email ?? '—'}
                  </td>
                  <td className="px-3 py-2 text-slate-800">
                    <span className="font-medium">
                      {row.staff_display_name ?? row.staff_full_name ?? '—'}
                    </span>
                    {row.staff_display_name &&
                    row.staff_full_name &&
                    row.staff_display_name.trim() !==
                      row.staff_full_name.trim() ? (
                      <span className="ml-1 text-slate-500">
                        ({row.staff_full_name})
                      </span>
                    ) : null}
                  </td>
                  <td className="px-3 py-2 text-sm text-slate-800">
                    {accessRoleDisplayLabel(row.access_role)}
                  </td>
                  <td className="px-3 py-2">
                    {row.is_active ? (
                      <span className="text-emerald-700">Yes</span>
                    ) : (
                      <span className="text-slate-500">No</span>
                    )}
                  </td>
                  <td className="px-3 py-2 text-xs text-slate-600">
                    {formatShortDate(row.updated_at)}
                  </td>
                  <td className="px-3 py-2 text-right">
                    {canManage ? (
                      <div className="flex flex-wrap justify-end gap-2">
                        <button
                          type="button"
                          className="rounded border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                          onClick={() => openEdit(row)}
                          disabled={updateMut.isPending}
                        >
                          Edit
                        </button>
                        <button
                          type="button"
                          className="rounded border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50"
                          onClick={() => toggleActive(row)}
                          disabled={updateMut.isPending}
                        >
                          {row.is_active ? 'Deactivate' : 'Activate'}
                        </button>
                      </div>
                    ) : (
                      <span className="text-xs text-slate-400">View only</span>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      {modalMode ? (
        <AccessMappingFormModal
          open
          mode={modalMode}
          initial={modalMode === 'edit' ? editRow : null}
          onClose={closeModal}
        />
      ) : null}

      {canManage ? (
        <InviteUserModal
          open={inviteOpen}
          onClose={() => setInviteOpen(false)}
          onInvite={async (email) => {
            await invokeInviteAccessUser(email)
            void queryClient.invalidateQueries({ queryKey: ['search-auth-users'] })
          }}
        />
      ) : null}
    </div>
  )
}
