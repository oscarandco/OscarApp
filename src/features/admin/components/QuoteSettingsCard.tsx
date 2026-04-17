import { type FormEvent, useEffect, useState } from 'react'

import type { QuoteSettings } from '@/features/admin/types/quoteConfiguration'

type QuoteSettingsCardProps = {
  settings: QuoteSettings
  onSave: (next: Omit<QuoteSettings, 'updatedAt'>) => void
}

export function QuoteSettingsCard({ settings, onSave }: QuoteSettingsCardProps) {
  const [greenFeeAmount, setGreenFeeAmount] = useState<string>(
    String(settings.greenFeeAmount ?? 0),
  )
  const [notesEnabled, setNotesEnabled] = useState<boolean>(settings.notesEnabled)
  const [guestNameRequired, setGuestNameRequired] = useState<boolean>(
    settings.guestNameRequired,
  )
  const [quotePageTitle, setQuotePageTitle] = useState<string>(
    settings.quotePageTitle,
  )
  const [active, setActive] = useState<boolean>(settings.active)
  const [error, setError] = useState<string | null>(null)
  const [justSaved, setJustSaved] = useState(false)

  useEffect(() => {
    setGreenFeeAmount(String(settings.greenFeeAmount ?? 0))
    setNotesEnabled(settings.notesEnabled)
    setGuestNameRequired(settings.guestNameRequired)
    setQuotePageTitle(settings.quotePageTitle)
    setActive(settings.active)
  }, [settings])

  function onSubmit(e: FormEvent) {
    e.preventDefault()
    setError(null)
    const fee = Number(greenFeeAmount)
    if (!Number.isFinite(fee) || fee < 0) {
      setError('Green Fee must be a number and at least 0.')
      return
    }
    if (quotePageTitle.trim() === '') {
      setError('Quote Page Title is required.')
      return
    }
    onSave({
      greenFeeAmount: fee,
      notesEnabled,
      guestNameRequired,
      quotePageTitle: quotePageTitle.trim(),
      active,
    })
    setJustSaved(true)
    window.setTimeout(() => setJustSaved(false), 2000)
  }

  return (
    <form
      onSubmit={onSubmit}
      className="mb-8 rounded-lg border border-slate-200 bg-white p-5 shadow-sm"
      data-testid="quote-settings-card"
    >
      <div className="mb-4">
        <h2 className="text-lg font-semibold text-slate-900">Quote Settings</h2>
        <p className="mt-1 text-sm text-slate-600">
          Global settings applied to every guest quote.
        </p>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div>
          <label
            htmlFor="qs-green-fee"
            className="block text-sm font-medium text-slate-700"
          >
            Green Fee Amount <span className="text-rose-600">*</span>
          </label>
          <div className="mt-1 flex rounded-md border border-slate-200">
            <span className="inline-flex items-center rounded-l-md border-r border-slate-200 bg-slate-50 px-3 text-sm text-slate-600">
              $
            </span>
            <input
              id="qs-green-fee"
              type="number"
              min={0}
              step={0.01}
              required
              value={greenFeeAmount}
              onChange={(e) => setGreenFeeAmount(e.target.value)}
              className="w-full rounded-r-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
              data-testid="quote-settings-green-fee"
            />
          </div>
          <p className="mt-1 text-xs text-slate-500">
            Applied automatically to every saved quote.
          </p>
        </div>

        <div>
          <label
            htmlFor="qs-page-title"
            className="block text-sm font-medium text-slate-700"
          >
            Quote Page Title <span className="text-rose-600">*</span>
          </label>
          <input
            id="qs-page-title"
            type="text"
            required
            value={quotePageTitle}
            onChange={(e) => setQuotePageTitle(e.target.value)}
            className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
            data-testid="quote-settings-page-title"
          />
        </div>

        <ToggleField
          id="qs-notes-enabled"
          label="Notes Enabled"
          description="Allow stylists to add free-form notes on a guest quote."
          checked={notesEnabled}
          onChange={setNotesEnabled}
          testId="quote-settings-notes-enabled"
        />

        <ToggleField
          id="qs-guest-name-required"
          label="Guest Name Required"
          description="Require a guest name before a quote can be saved."
          checked={guestNameRequired}
          onChange={setGuestNameRequired}
          testId="quote-settings-guest-name-required"
        />

        <ToggleField
          id="qs-active"
          label="Active"
          description="When off, the stylist-facing Guest Quote page is disabled."
          checked={active}
          onChange={setActive}
          testId="quote-settings-active"
        />
      </div>

      {error ? (
        <p
          className="mt-4 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-sm text-rose-700"
          role="alert"
        >
          {error}
        </p>
      ) : null}

      <div className="mt-5 flex items-center justify-end gap-3 border-t border-slate-100 pt-4">
        {justSaved ? (
          <span className="text-xs font-medium text-emerald-600">Saved</span>
        ) : null}
        <button
          type="submit"
          className="inline-flex items-center rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm transition hover:bg-violet-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1"
          data-testid="quote-settings-save"
        >
          Save Settings
        </button>
      </div>
    </form>
  )
}

type ToggleFieldProps = {
  id: string
  label: string
  description?: string
  checked: boolean
  onChange: (v: boolean) => void
  testId?: string
}

export function ToggleField({
  id,
  label,
  description,
  checked,
  onChange,
  testId,
}: ToggleFieldProps) {
  return (
    <div className="flex items-start gap-3">
      <button
        id={id}
        type="button"
        role="switch"
        aria-checked={checked}
        onClick={() => onChange(!checked)}
        data-testid={testId}
        className={`mt-0.5 inline-flex h-6 w-11 shrink-0 items-center rounded-full transition focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1 ${
          checked ? 'bg-violet-600' : 'bg-slate-300'
        }`}
      >
        <span
          className={`inline-block h-5 w-5 transform rounded-full bg-white shadow transition ${
            checked ? 'translate-x-5' : 'translate-x-0.5'
          }`}
          aria-hidden="true"
        />
      </button>
      <label htmlFor={id} className="select-none">
        <span className="block text-sm font-medium text-slate-800">{label}</span>
        {description ? (
          <span className="mt-0.5 block text-xs text-slate-500">{description}</span>
        ) : null}
      </label>
    </div>
  )
}
