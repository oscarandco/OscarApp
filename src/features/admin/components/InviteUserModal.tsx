import { type FormEvent, useEffect, useState } from 'react'

type InviteUserModalProps = {
  open: boolean
  onClose: () => void
  onInvite: (email: string) => Promise<void>
}

export function InviteUserModal({ open, onClose, onInvite }: InviteUserModalProps) {
  const [email, setEmail] = useState('')
  const [pending, setPending] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [success, setSuccess] = useState(false)

  useEffect(() => {
    if (!open) return
    setEmail('')
    setError(null)
    setSuccess(false)
    setPending(false)
  }, [open])

  if (!open) return null

  async function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    setSuccess(false)
    const trimmed = email.trim()
    if (!trimmed) {
      setError('Enter an email address.')
      return
    }
    setPending(true)
    try {
      await onInvite(trimmed)
      setSuccess(true)
      setEmail('')
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setPending(false)
    }
  }

  return (
    <div
      className="fixed inset-0 z-50 flex items-center justify-center bg-black/40 p-4"
      role="dialog"
      aria-modal="true"
      aria-labelledby="invite-user-title"
    >
      <div className="w-full max-w-md rounded-lg border border-slate-200 bg-white p-5 shadow-lg">
        <h2
          id="invite-user-title"
          className="text-lg font-semibold text-slate-900"
        >
          Invite user
        </h2>
        <p className="mt-2 text-sm text-slate-600">
          We&apos;ll send them an email with a link to set their password and sign
          in. After they accept, use{' '}
          <span className="font-medium">Create mapping</span> to link their
          account to a staff member.
        </p>
        <form onSubmit={onSubmit} className="mt-4 space-y-4">
          <div>
            <label
              htmlFor="invite-email"
              className="block text-sm font-medium text-slate-700"
            >
              Email
            </label>
            <input
              id="invite-email"
              type="email"
              autoComplete="email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm"
              data-testid="invite-user-email"
              disabled={pending}
            />
          </div>
          {success ? (
            <p
              className="text-sm text-emerald-800"
              data-testid="invite-user-success"
            >
              Invite sent. They should check their inbox (and spam folder).
            </p>
          ) : null}
          {error ? (
            <p className="text-sm text-red-700" data-testid="invite-user-error">
              {error}
            </p>
          ) : null}
          <div className="flex justify-end gap-2 pt-1">
            <button
              type="button"
              onClick={onClose}
              className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
              disabled={pending}
            >
              {success ? 'Close' : 'Cancel'}
            </button>
            {!success ? (
              <button
                type="submit"
                disabled={pending}
                className="rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white hover:bg-violet-700 disabled:opacity-50"
                data-testid="invite-user-submit"
              >
                {pending ? 'Sending…' : 'Send invite'}
              </button>
            ) : null}
          </div>
        </form>
      </div>
    </div>
  )
}
