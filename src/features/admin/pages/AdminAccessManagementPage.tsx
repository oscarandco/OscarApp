import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useMemo, useState } from 'react'

import { AccessMappingFormModal } from '@/features/admin/components/AccessMappingFormModal'
import { InviteUserModal } from '@/features/admin/components/InviteUserModal'
import { useAdminAccessMappings } from '@/features/admin/hooks/useAdminAccessMappings'
import { useAuthUserSearch } from '@/features/admin/hooks/useAccessMappingSearch'
import { useUpdateAccessMappingMutation } from '@/features/admin/hooks/useAccessMappingMutations'
import {
  accessRoleDisplayLabel,
  normalizeAccessRoleForForm,
  type AdminAccessMappingRow,
  type AuthUserSearchRow,
} from '@/features/admin/types/accessManagement'
import { canManageStaffAccessMappings } from '@/features/access/accessPermissions'
import { useAccessProfile } from '@/features/access/accessContext'
import { ConfirmDialog } from '@/components/feedback/ConfirmDialog'
import { EmptyState } from '@/components/feedback/EmptyState'
import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import {
  formatDateTimeCompact,
  formatRelativeTime,
  formatShortDate,
} from '@/lib/formatters'
import { queryErrorDetail } from '@/lib/queryError'
import { invokeInviteAccessUser } from '@/lib/inviteAccessUser'
import { invokeAdminSendPasswordReset } from '@/lib/adminSendPasswordReset'
import { invokeAdminDeleteUser } from '@/lib/adminDeleteUser'

/**
 * Minimal status-banner model. Using a single shared banner (rather
 * than bringing in a full toast system) keeps the change surface
 * small and consistent with how `updateMut.isError` already renders
 * below the page header.
 */
type FeedbackState =
  | { kind: 'success'; message: string }
  | { kind: 'error'; message: string }
  | null

/**
 * Shared target shape for reset/delete mutations so per-row busy flags
 * work uniformly across "pending" pseudo-rows (no mapping) and real
 * mapping rows.
 */
type UserTarget = { userId: string; email: string | null }

/** Generic confirm-delete dialog target: enough to show a helpful description. */
type DeleteTarget = { userId: string; email: string | null }

export function AdminAccessManagementPage() {
  const queryClient = useQueryClient()
  const { normalized } = useAccessProfile()
  const canManage = canManageStaffAccessMappings(normalized)

  const { data, isLoading, isError, error, refetch } = useAdminAccessMappings()
  // `search_auth_users(null)` already only returns auth users WITHOUT any
  // staff_member_user_access row, i.e. exactly our "pending mapping" set.
  const pendingQ = useAuthUserSearch('', canManage)
  const updateMut = useUpdateAccessMappingMutation()

  const [modalMode, setModalMode] = useState<'create' | 'edit' | null>(null)
  const [editRow, setEditRow] = useState<AdminAccessMappingRow | null>(null)
  const [createPrefill, setCreatePrefill] = useState<AuthUserSearchRow | null>(
    null,
  )
  const [inviteOpen, setInviteOpen] = useState(false)
  const [confirmDelete, setConfirmDelete] = useState<DeleteTarget | null>(null)
  const [feedback, setFeedback] = useState<FeedbackState>(null)

  const resetMut = useMutation({
    mutationFn: async (t: UserTarget) => {
      if (!t.email) {
        throw new Error('This user has no email on file.')
      }
      await invokeAdminSendPasswordReset(t.email)
      return t.email
    },
    onSuccess: (email) => {
      setFeedback({
        kind: 'success',
        message: `Password reset email sent to ${email}.`,
      })
    },
    onError: (err) => {
      setFeedback({
        kind: 'error',
        message:
          err instanceof Error ? err.message : 'Failed to send password reset.',
      })
    },
  })

  const deleteMut = useMutation({
    mutationFn: async (t: UserTarget) => {
      await invokeAdminDeleteUser(t.userId)
      return t
    },
    onSuccess: (t) => {
      setFeedback({
        kind: 'success',
        message: `Deleted user${t.email ? ` ${t.email}` : ''}.`,
      })
      void queryClient.invalidateQueries({ queryKey: ['admin-access-mappings'] })
      void queryClient.invalidateQueries({ queryKey: ['search-auth-users'] })
      void refetch()
      void pendingQ.refetch()
    },
    onError: (err) => {
      setFeedback({
        kind: 'error',
        message: err instanceof Error ? err.message : 'Failed to delete user.',
      })
    },
  })

  const pendingUsers: AuthUserSearchRow[] = pendingQ.data ?? []

  // Group users into exactly one of the three sections. Row-level grouping
  // preserves the existing per-mapping UI (one row per mapping), while the
  // "inactive" bucket suppresses any user who also has an active mapping
  // so a user appears in only one section.
  const { activeRows, inactiveRows } = useMemo(() => {
    const mappings = data ?? []
    const active = mappings.filter((m) => m.is_active)
    const usersWithActive = new Set(active.map((m) => m.user_id))
    const inactive = mappings.filter(
      (m) => !m.is_active && !usersWithActive.has(m.user_id),
    )
    return { activeRows: active, inactiveRows: inactive }
  }, [data])

  function openCreateForPending(u: AuthUserSearchRow) {
    if (!canManage) return
    setFeedback(null)
    setEditRow(null)
    setCreatePrefill(u)
    setModalMode('create')
  }

  function openCreate() {
    setEditRow(null)
    setCreatePrefill(null)
    setModalMode('create')
  }

  function openEdit(row: AdminAccessMappingRow) {
    setEditRow(row)
    setCreatePrefill(null)
    setModalMode('edit')
  }

  function closeModal() {
    setModalMode(null)
    setEditRow(null)
    setCreatePrefill(null)
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

  function sendReset(t: UserTarget) {
    if (!canManage) return
    setFeedback(null)
    resetMut.mutate(t)
  }

  function requestDelete(t: DeleteTarget) {
    if (!canManage) return
    setFeedback(null)
    setConfirmDelete(t)
  }

  function doConfirmDelete() {
    const t = confirmDelete
    if (!t) return
    setConfirmDelete(null)
    deleteMut.mutate({ userId: t.userId, email: t.email })
  }

  /** True while any of the three mutations are in flight (global lock). */
  const anyMutBusy =
    updateMut.isPending || resetMut.isPending || deleteMut.isPending

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

  return (
    <div data-testid="admin-access-page">
      <PageHeader
        title="Access management"
        description="Link Supabase accounts to staff members. Only admins can create or change mappings; managers can view this list."
      />

      <div className="mb-4 flex flex-wrap items-center justify-between gap-3">
        <p className="text-sm text-slate-600">
          {activeRows.length} active · {inactiveRows.length} inactive ·{' '}
          {pendingUsers.length} pending
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

      {feedback ? (
        <div
          role="status"
          aria-live="polite"
          className={
            feedback.kind === 'success'
              ? 'mb-4 flex items-start justify-between gap-3 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm text-emerald-800'
              : 'mb-4 flex items-start justify-between gap-3 rounded-md border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-800'
          }
          data-testid={
            feedback.kind === 'success'
              ? 'admin-access-feedback-success'
              : 'admin-access-feedback-error'
          }
        >
          <span>{feedback.message}</span>
          <button
            type="button"
            onClick={() => setFeedback(null)}
            className="text-xs font-medium underline hover:no-underline"
          >
            Dismiss
          </button>
        </div>
      ) : null}

      {updateMut.isError ? (
        <p className="mb-4 text-sm text-red-700">
          {updateMut.error instanceof Error
            ? updateMut.error.message
            : String(updateMut.error)}
        </p>
      ) : null}

      {/* Section 1 — Users pending mapping */}
      <SectionHeader
        title="Users pending mapping"
        description="Users who can access the system but are not yet linked to a staff member."
        count={pendingUsers.length}
        testId="admin-access-section-pending"
      />
      {pendingQ.isLoading ? (
        <LoadingState
          message="Loading pending users…"
          testId="admin-access-pending-loading"
        />
      ) : pendingUsers.length === 0 ? (
        <EmptyState
          title="No pending users"
          description="Invited users with no staff mapping will appear here."
          testId="admin-access-pending-empty"
        />
      ) : (
        <div className="mb-8 overflow-x-auto rounded-lg border border-slate-200 bg-white shadow-sm">
          <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
            <thead className="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-600">
              <tr>
                <th className="px-3 py-3">Email</th>
                <th className="px-3 py-3">Created</th>
                <th className="px-3 py-3">Last login</th>
                <th className="px-3 py-3 text-right">Actions</th>
              </tr>
            </thead>
            <tbody className="divide-y divide-slate-100">
              {pendingUsers.map((u) => {
                const target: UserTarget = { userId: u.user_id, email: u.email }
                const resetBusy =
                  resetMut.isPending &&
                  resetMut.variables?.userId === u.user_id
                const deleteBusy =
                  deleteMut.isPending &&
                  deleteMut.variables?.userId === u.user_id
                return (
                  <tr key={u.user_id} className="bg-white">
                    <td className="px-3 py-2 font-mono text-xs text-slate-900">
                      {u.email ?? u.user_id}
                    </td>
                    <td className="px-3 py-2 text-xs text-slate-600">
                      {formatShortDate(u.created_at)}
                    </td>
                    <td className="px-3 py-2">
                      <LastLoginCell iso={u.last_sign_in_at} />
                    </td>
                    <td className="px-3 py-2 text-right">
                      {canManage ? (
                        <div className="flex flex-wrap justify-end gap-2">
                          <button
                            type="button"
                            className="rounded border border-violet-200 bg-white px-2 py-1 text-xs font-medium text-violet-800 hover:bg-violet-50 disabled:cursor-not-allowed disabled:opacity-60"
                            onClick={() => openCreateForPending(u)}
                            disabled={anyMutBusy}
                            data-testid={`admin-access-pending-create-${u.user_id}`}
                          >
                            Create mapping
                          </button>
                          <button
                            type="button"
                            className="rounded border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-60"
                            onClick={() => sendReset(target)}
                            disabled={!u.email || anyMutBusy}
                            title={
                              u.email
                                ? 'Send password reset email'
                                : 'No email on file for this user'
                            }
                            data-testid={`admin-access-pending-reset-${u.user_id}`}
                          >
                            {resetBusy ? 'Sending…' : 'Reset password'}
                          </button>
                          <button
                            type="button"
                            className="rounded border border-rose-200 bg-white px-2 py-1 text-xs font-medium text-rose-700 hover:bg-rose-50 disabled:cursor-not-allowed disabled:opacity-60"
                            onClick={() => requestDelete(target)}
                            disabled={anyMutBusy}
                            data-testid={`admin-access-pending-delete-${u.user_id}`}
                          >
                            {deleteBusy ? 'Deleting…' : 'Delete user'}
                          </button>
                        </div>
                      ) : (
                        <span className="text-xs text-slate-400">View only</span>
                      )}
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* Section 2 — Active users */}
      <SectionHeader
        title="Active users"
        description="Users currently linked to a staff member and able to use their assigned access role."
        count={activeRows.length}
        testId="admin-access-section-active"
      />
      {activeRows.length === 0 ? (
        <EmptyState
          title="No active users"
          description="When a user has an active staff mapping, they will appear here."
          testId="admin-access-active-empty"
        />
      ) : (
        <MappingTable
          rows={activeRows}
          variant="active"
          canManage={canManage}
          anyMutBusy={anyMutBusy}
          updateBusyMappingId={
            updateMut.isPending ? updateMut.variables?.mappingId ?? null : null
          }
          resetBusyUserId={
            resetMut.isPending ? resetMut.variables?.userId ?? null : null
          }
          deleteBusyUserId={
            deleteMut.isPending ? deleteMut.variables?.userId ?? null : null
          }
          onEdit={openEdit}
          onToggleActive={toggleActive}
          onSendReset={sendReset}
          onRequestDelete={requestDelete}
        />
      )}

      {/* Section 3 — Inactive users */}
      <SectionHeader
        title="Inactive users"
        description="Users who have historical staff links but are not currently active."
        count={inactiveRows.length}
        testId="admin-access-section-inactive"
      />
      {inactiveRows.length === 0 ? (
        <EmptyState
          title="No inactive users"
          description="Historical mappings with no active access will appear here."
          testId="admin-access-inactive-empty"
        />
      ) : (
        <MappingTable
          rows={inactiveRows}
          variant="inactive"
          canManage={canManage}
          anyMutBusy={anyMutBusy}
          updateBusyMappingId={
            updateMut.isPending ? updateMut.variables?.mappingId ?? null : null
          }
          resetBusyUserId={
            resetMut.isPending ? resetMut.variables?.userId ?? null : null
          }
          deleteBusyUserId={
            deleteMut.isPending ? deleteMut.variables?.userId ?? null : null
          }
          onEdit={openEdit}
          onToggleActive={toggleActive}
          onSendReset={sendReset}
          onRequestDelete={requestDelete}
        />
      )}

      {modalMode ? (
        <AccessMappingFormModal
          open
          mode={modalMode}
          initial={modalMode === 'edit' ? editRow : null}
          prefillUser={modalMode === 'create' ? createPrefill : null}
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

      <ConfirmDialog
        open={confirmDelete != null}
        title="Delete this user?"
        description={
          confirmDelete
            ? `This will permanently delete the Supabase account${
                confirmDelete.email ? ` for ${confirmDelete.email}` : ''
              } and remove any inactive access-mapping history. The user will not be able to sign in again. This is intended for mistaken invites, duplicates, or unused accounts — for real off-boarding use Deactivate instead.`
            : ''
        }
        confirmLabel="Delete user"
        cancelLabel="Cancel"
        tone="danger"
        onConfirm={doConfirmDelete}
        onClose={() => setConfirmDelete(null)}
        testId="admin-access-delete-confirm"
      />
    </div>
  )
}

/**
 * Renders the auth.users.last_sign_in_at value as:
 *   • primary line: relative ("2 days ago")
 *   • secondary muted line: exact local datetime ("18 Apr 2026, 14:35")
 *
 * When the user has never signed in (null/invalid timestamp) the cell
 * shows the single word `Never` in muted text.
 */
function LastLoginCell({ iso }: { iso: string | null | undefined }) {
  const relative = formatRelativeTime(iso)
  if (!iso || !relative) {
    return <span className="text-xs text-slate-500">Never</span>
  }
  return (
    <div className="leading-tight">
      <div className="text-xs text-slate-800">{relative}</div>
      <div className="text-[11px] text-slate-500">
        {formatDateTimeCompact(iso)}
      </div>
    </div>
  )
}

function SectionHeader({
  title,
  description,
  count,
  testId,
}: {
  title: string
  description: string
  count: number
  testId?: string
}) {
  return (
    <div className="mb-2 mt-6 flex flex-wrap items-end justify-between gap-2" data-testid={testId}>
      <div>
        <h2 className="text-base font-semibold text-slate-900">{title}</h2>
        <p className="text-xs text-slate-600">{description}</p>
      </div>
      <span className="text-xs text-slate-500">
        {count} user{count === 1 ? '' : 's'}
      </span>
    </div>
  )
}

/**
 * Shared table for Active and Inactive mapping rows. The set of row
 * actions differs per variant:
 *  - active   → Edit, Deactivate, Reset password
 *  - inactive → Edit, Activate, Reset password, Delete user
 *    (the backend still enforces the `still_linked` safety check, so
 *    this button is always safe to surface — the server will refuse if
 *    the user has any OTHER active mapping we don't know about here.)
 */
function MappingTable({
  rows,
  variant,
  canManage,
  anyMutBusy,
  updateBusyMappingId,
  resetBusyUserId,
  deleteBusyUserId,
  onEdit,
  onToggleActive,
  onSendReset,
  onRequestDelete,
}: {
  rows: readonly AdminAccessMappingRow[]
  variant: 'active' | 'inactive'
  canManage: boolean
  anyMutBusy: boolean
  updateBusyMappingId: string | null
  resetBusyUserId: string | null
  deleteBusyUserId: string | null
  onEdit: (row: AdminAccessMappingRow) => void
  onToggleActive: (row: AdminAccessMappingRow) => void
  onSendReset: (t: UserTarget) => void
  onRequestDelete: (t: DeleteTarget) => void
}) {
  return (
    <div className="mb-8 overflow-x-auto rounded-lg border border-slate-200 bg-white shadow-sm">
      <table className="min-w-full divide-y divide-slate-200 text-left text-sm">
        <thead className="bg-slate-50 text-xs font-semibold uppercase tracking-wide text-slate-600">
          <tr>
            <th className="px-3 py-3">Email</th>
            <th className="px-3 py-3">Staff</th>
            <th className="px-3 py-3">Role</th>
            <th className="px-3 py-3">Last login</th>
            <th className="px-3 py-3">Updated</th>
            <th className="px-3 py-3 text-right">Actions</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-slate-100">
          {rows.map((row) => {
            const target: UserTarget = {
              userId: row.user_id,
              email: row.email,
            }
            const updateBusy = updateBusyMappingId === row.mapping_id
            const resetBusy = resetBusyUserId === row.user_id
            const deleteBusy = deleteBusyUserId === row.user_id
            return (
              <tr
                key={row.mapping_id}
                className={
                  variant === 'active'
                    ? 'bg-white'
                    : 'bg-slate-50/80 text-slate-600'
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
                  <LastLoginCell iso={row.last_sign_in_at} />
                </td>
                <td className="px-3 py-2 text-xs text-slate-600">
                  {formatShortDate(row.updated_at)}
                </td>
                <td className="px-3 py-2 text-right">
                  {canManage ? (
                    <div className="flex flex-wrap justify-end gap-2">
                      <button
                        type="button"
                        className="rounded border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-60"
                        onClick={() => onEdit(row)}
                        disabled={anyMutBusy}
                      >
                        Edit
                      </button>
                      <button
                        type="button"
                        className="rounded border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-60"
                        onClick={() => onToggleActive(row)}
                        disabled={anyMutBusy}
                      >
                        {updateBusy
                          ? 'Saving…'
                          : row.is_active
                            ? 'Deactivate'
                            : 'Activate'}
                      </button>
                      <button
                        type="button"
                        className="rounded border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-60"
                        onClick={() => onSendReset(target)}
                        disabled={!row.email || anyMutBusy}
                        title={
                          row.email
                            ? 'Send password reset email'
                            : 'No email on file for this user'
                        }
                        data-testid={`admin-access-reset-${row.mapping_id}`}
                      >
                        {resetBusy ? 'Sending…' : 'Reset password'}
                      </button>
                      {variant === 'inactive' ? (
                        <button
                          type="button"
                          className="rounded border border-rose-200 bg-white px-2 py-1 text-xs font-medium text-rose-700 hover:bg-rose-50 disabled:cursor-not-allowed disabled:opacity-60"
                          onClick={() => onRequestDelete(target)}
                          disabled={anyMutBusy}
                          data-testid={`admin-access-delete-${row.mapping_id}`}
                        >
                          {deleteBusy ? 'Deleting…' : 'Delete user'}
                        </button>
                      ) : null}
                    </div>
                  ) : (
                    <span className="text-xs text-slate-400">View only</span>
                  )}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
    </div>
  )
}
