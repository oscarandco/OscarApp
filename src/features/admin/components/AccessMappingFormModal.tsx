import { useEffect, useState, type FormEvent } from 'react'

import {
  ACCESS_ROLE_OPTIONS,
  accessRoleDisplayLabel,
  normalizeAccessRoleForForm,
  roleShowsStaffMemberField,
  staffMemberRequiredForRole,
  type AdminAccessMappingRow,
  type AuthUserSearchRow,
  type StaffMemberSearchRow,
} from '@/features/admin/types/accessManagement'
import {
  useAuthUserSearch,
  useStaffMemberSearch,
} from '@/features/admin/hooks/useAccessMappingSearch'
import {
  useCreateAccessMappingMutation,
  useUpdateAccessMappingMutation,
} from '@/features/admin/hooks/useAccessMappingMutations'
import { formatShortDate } from '@/lib/formatters'
import { useDebouncedValue } from '@/lib/useDebouncedValue'

type AccessMappingFormModalProps = {
  open: boolean
  mode: 'create' | 'edit'
  initial: AdminAccessMappingRow | null
  onClose: () => void
}

function staffLabel(s: StaffMemberSearchRow): string {
  const a = (s.display_name ?? '').trim()
  const b = (s.full_name ?? '').trim()
  if (a && b) return `${a} — ${b}`
  return a || b || '—'
}

export function AccessMappingFormModal({
  open,
  mode,
  initial,
  onClose,
}: AccessMappingFormModalProps) {
  const createMut = useCreateAccessMappingMutation()
  const updateMut = useUpdateAccessMappingMutation()

  const [authSearch, setAuthSearch] = useState('')
  const debouncedAuth = useDebouncedValue(authSearch, 350)
  const [staffSearch, setStaffSearch] = useState('')
  const debouncedStaff = useDebouncedValue(staffSearch, 350)

  const [pickedUser, setPickedUser] = useState<AuthUserSearchRow | null>(null)
  const [pickedStaff, setPickedStaff] = useState<StaffMemberSearchRow | null>(
    null,
  )
  const [accessRole, setAccessRole] = useState('stylist')
  const [isActive, setIsActive] = useState(true)

  const safeRole = normalizeAccessRoleForForm(accessRole)
  const showStaffField = roleShowsStaffMemberField(safeRole)
  const strictStaff = staffMemberRequiredForRole(safeRole)

  const authQ = useAuthUserSearch(debouncedAuth, open && mode === 'create')
  const staffQ = useStaffMemberSearch(debouncedStaff, open && showStaffField)

  function handleAccessRoleChange(nextRaw: string) {
    setAccessRole(nextRaw)
    const next = normalizeAccessRoleForForm(nextRaw)
    if (next === 'admin') {
      setPickedStaff(null)
      setStaffSearch('')
    }
  }

  useEffect(() => {
    if (!open) return
    createMut.reset()
    updateMut.reset()
    if (mode === 'create') {
      setAuthSearch('')
      setStaffSearch('')
      setPickedUser(null)
      setPickedStaff(null)
      setAccessRole('stylist')
      setIsActive(true)
    } else if (mode === 'edit' && initial) {
      setAuthSearch('')
      setStaffSearch('')
      setPickedUser({
        user_id: initial.user_id,
        email: initial.email,
      })
      const r = normalizeAccessRoleForForm(initial.access_role)
      setAccessRole(r)
      if (r === 'admin') {
        setPickedStaff(null)
      } else if (initial.staff_member_id) {
        setPickedStaff({
          staff_member_id: initial.staff_member_id,
          display_name: initial.staff_display_name,
          full_name: initial.staff_full_name,
        })
      } else {
        setPickedStaff(null)
      }
      setIsActive(initial.is_active)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- reset mutation errors when dialog opens
  }, [open, mode, initial?.mapping_id])

  const pending = createMut.isPending || updateMut.isPending
  const mutError = createMut.error ?? updateMut.error

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    const role = normalizeAccessRoleForForm(accessRole)
    const staffMemberId =
      role === 'admin' ? null : (pickedStaff?.staff_member_id ?? null)

    if (staffMemberRequiredForRole(role) && !staffMemberId) return

    if (mode === 'create') {
      if (!pickedUser) return
      await createMut.mutateAsync({
        userId: pickedUser.user_id,
        staffMemberId,
        accessRole: role,
        isActive,
      })
      onClose()
      return
    }
    if (!initial) return
    await updateMut.mutateAsync({
      mappingId: initial.mapping_id,
      staffMemberId,
      accessRole: role,
      isActive,
    })
    onClose()
  }

  const submitDisabled =
    pending ||
    !safeRole ||
    (mode === 'create' && !pickedUser) ||
    (strictStaff && !pickedStaff?.staff_member_id)

  if (!open) return null
  if (mode === 'edit' && !initial) return null

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-slate-900/40 px-4 py-8"
      role="dialog"
      aria-modal="true"
      aria-labelledby="access-mapping-modal-title"
    >
      <div className="max-h-[90vh] w-full max-w-lg overflow-y-auto rounded-xl border border-slate-200 bg-white p-6 shadow-lg">
        <h2
          id="access-mapping-modal-title"
          className="text-lg font-semibold text-slate-900"
        >
          {mode === 'create' ? 'Create access mapping' : 'Edit access mapping'}
        </h2>
        <p className="mt-1 text-sm text-slate-600">
          {mode === 'create'
            ? 'Choose the account and role. Stylist and Assistant need a staff member; Manager can optionally link one; Admin does not use staff linking.'
            : 'Update role and access. Stylist and Assistant require a staff member; Manager is optional; Admin clears staff linking.'}
        </p>

        <form className="mt-6 space-y-5" onSubmit={(e) => void onSubmit(e)}>
          {mode === 'edit' && initial ? (
            <div className="rounded-lg border border-slate-100 bg-slate-50 px-3 py-2 text-sm">
              <p>
                <span className="font-medium text-slate-700">Auth user</span>
                <br />
                <span className="font-mono text-slate-900">
                  {initial.email ?? '—'}
                </span>
              </p>
              <p className="mt-2 text-xs text-slate-500">
                User cannot be changed. Created{' '}
                {formatShortDate(initial.created_at)} · Updated{' '}
                {formatShortDate(initial.updated_at)}
              </p>
            </div>
          ) : null}

          {mode === 'create' ? (
            <div>
              <label className="block text-sm font-medium text-slate-700">
                Auth user
              </label>
              <p className="mt-0.5 text-xs text-slate-500">
                Search by email. Users who already have a mapping are hidden.
              </p>
              <input
                type="search"
                value={authSearch}
                onChange={(e) => setAuthSearch(e.target.value)}
                className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm"
                placeholder="Search email…"
                autoComplete="off"
                data-testid="access-modal-auth-search"
              />
              {authQ.isLoading ? (
                <p className="mt-2 text-xs text-slate-500">Searching…</p>
              ) : authQ.isError ? (
                <p className="mt-2 text-xs text-red-600">Could not search users.</p>
              ) : (
                <ul
                  className="mt-2 max-h-36 overflow-y-auto rounded-md border border-slate-100"
                  data-testid="access-modal-auth-results"
                >
                  {(authQ.data ?? []).map((u) => (
                    <li key={u.user_id}>
                      <button
                        type="button"
                        className={
                          pickedUser?.user_id === u.user_id
                            ? 'w-full bg-violet-50 px-3 py-2 text-left text-sm text-violet-900'
                            : 'w-full px-3 py-2 text-left text-sm text-slate-800 hover:bg-slate-50'
                        }
                        onClick={() => setPickedUser(u)}
                      >
                        <span className="font-mono">{u.email ?? u.user_id}</span>
                      </button>
                    </li>
                  ))}
                </ul>
              )}
              {pickedUser ? (
                <p className="mt-2 text-xs text-slate-600">
                  Selected:{' '}
                  <span className="font-mono">{pickedUser.email}</span>
                </p>
              ) : null}
            </div>
          ) : null}

          <div>
            <label
              htmlFor="access-role"
              className="block text-sm font-medium text-slate-700"
            >
              Access role
            </label>
            <select
              id="access-role"
              value={accessRole}
              onChange={(e) => handleAccessRoleChange(e.target.value)}
              className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm"
              data-testid="access-modal-role"
            >
              {ACCESS_ROLE_OPTIONS.map((o) => (
                <option key={o.value} value={o.value}>
                  {o.label}
                </option>
              ))}
              {accessRole &&
              !ACCESS_ROLE_OPTIONS.some((o) => o.value === accessRole) ? (
                <option
                  key={`access-role-legacy-${accessRole}`}
                  value={accessRole}
                >
                  {accessRoleDisplayLabel(accessRole)}
                </option>
              ) : null}
            </select>
          </div>

          {showStaffField ? (
            <div>
              <label className="block text-sm font-medium text-slate-700">
                Staff member
              </label>
              <p className="mt-0.5 text-xs text-slate-500">
                {strictStaff
                  ? 'Required for Stylist and Assistant.'
                  : 'Optional for Manager — leave empty if this login is not tied to one staff profile.'}
              </p>
              <input
                type="search"
                value={staffSearch}
                onChange={(e) => setStaffSearch(e.target.value)}
                className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm"
                placeholder="Search display or full name…"
                autoComplete="off"
                data-testid="access-modal-staff-search"
              />
              {staffQ.isLoading ? (
                <p className="mt-2 text-xs text-slate-500">Searching…</p>
              ) : staffQ.isError ? (
                <p className="mt-2 text-xs text-red-600">Could not search staff.</p>
              ) : (
                <ul
                  className="mt-2 max-h-36 overflow-y-auto rounded-md border border-slate-100"
                  data-testid="access-modal-staff-results"
                >
                  {(staffQ.data ?? []).map((s) => (
                    <li key={s.staff_member_id}>
                      <button
                        type="button"
                        className={
                          pickedStaff?.staff_member_id === s.staff_member_id
                            ? 'w-full bg-violet-50 px-3 py-2 text-left text-sm text-violet-900'
                            : 'w-full px-3 py-2 text-left text-sm text-slate-800 hover:bg-slate-50'
                        }
                        onClick={() => setPickedStaff(s)}
                      >
                        {staffLabel(s)}
                      </button>
                    </li>
                  ))}
                </ul>
              )}
              {pickedStaff ? (
                <p className="mt-2 text-xs text-slate-600">
                  Selected: {staffLabel(pickedStaff)}
                </p>
              ) : null}
            </div>
          ) : null}

          <label className="flex items-center gap-2 text-sm text-slate-800">
            <input
              type="checkbox"
              checked={isActive}
              onChange={(e) => setIsActive(e.target.checked)}
              data-testid="access-modal-active"
            />
            Access is active
          </label>

          {mutError ? (
            <p className="text-sm text-red-700" data-testid="access-modal-error">
              {mutError instanceof Error
                ? mutError.message
                : String(mutError)}
            </p>
          ) : null}

          <div className="flex flex-wrap justify-end gap-2 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-md border border-slate-200 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              disabled={pending}
            >
              Cancel
            </button>
            <button
              type="submit"
              disabled={submitDisabled}
              className="rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:cursor-not-allowed disabled:opacity-50"
              data-testid="access-modal-submit"
            >
              {pending ? 'Saving…' : mode === 'create' ? 'Create mapping' : 'Save changes'}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
