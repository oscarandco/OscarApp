import { useMutation, useQueryClient } from '@tanstack/react-query'
import { useEffect, useMemo, useState } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { PageHeader } from '@/components/layout/PageHeader'
import { useIsPageViewOnly } from '@/features/access/pageAccess'
import {
  BUSINESS_SETTINGS_QUERY_KEY,
  useBusinessSettings,
} from '@/features/admin/hooks/useBusinessSettings'
import {
  businessSettingsMissingRequiredFields,
  type BusinessSettingsRow,
} from '@/features/admin/types/businessSettings'
import { BUSINESS_SETTINGS_FIELD_LABELS } from '@/features/admin/types/contractorInvoice'
import { rpcUpdateBusinessSettings } from '@/lib/contractorInvoicesApi'
import { queryErrorDetail } from '@/lib/queryError'

type Draft = {
  legal_business_name: string
  trading_name: string
  street_address: string
  suburb: string
  city_postcode: string
  email: string
  phone: string
  nzbn: string
  gst_number: string
}

const EMPTY_DRAFT: Draft = {
  legal_business_name: '',
  trading_name: '',
  street_address: '',
  suburb: '',
  city_postcode: '',
  email: '',
  phone: '',
  nzbn: '',
  gst_number: '',
}

function rowToDraft(row: BusinessSettingsRow | null | undefined): Draft {
  if (!row) return { ...EMPTY_DRAFT }
  return {
    legal_business_name: row.legal_business_name ?? '',
    trading_name: row.trading_name ?? '',
    street_address: row.street_address ?? '',
    suburb: row.suburb ?? '',
    city_postcode: row.city_postcode ?? '',
    email: row.email ?? '',
    phone: row.phone ?? '',
    nzbn: row.nzbn ?? '',
    gst_number: row.gst_number ?? '',
  }
}

function inputClass(): string {
  return 'mt-1 w-full rounded-md border border-slate-300 px-3 py-2 text-sm shadow-sm focus:border-violet-500 focus:outline-none focus:ring-1 focus:ring-violet-500'
}

export function AdminBusinessSettingsPage() {
  const queryClient = useQueryClient()
  const settingsQuery = useBusinessSettings()
  const viewOnly = useIsPageViewOnly('business_settings')

  const [draft, setDraft] = useState<Draft>(EMPTY_DRAFT)
  const [feedback, setFeedback] = useState<
    | { kind: 'success'; message: string }
    | { kind: 'error'; message: string }
    | null
  >(null)

  useEffect(() => {
    if (settingsQuery.data !== undefined) {
      setDraft(rowToDraft(settingsQuery.data))
    }
  }, [settingsQuery.data])

  const dirty = useMemo(() => {
    const base = rowToDraft(settingsQuery.data ?? null)
    return (Object.keys(EMPTY_DRAFT) as (keyof Draft)[]).some(
      (k) => (base[k] ?? '').trim() !== (draft[k] ?? '').trim(),
    )
  }, [draft, settingsQuery.data])

  const missing = useMemo(
    () => businessSettingsMissingRequiredFields(settingsQuery.data ?? null),
    [settingsQuery.data],
  )

  const saveMut = useMutation({
    mutationFn: async () => {
      await rpcUpdateBusinessSettings({
        legal_business_name: draft.legal_business_name.trim(),
        trading_name: draft.trading_name.trim() || null,
        street_address: draft.street_address.trim(),
        suburb: draft.suburb.trim(),
        city_postcode: draft.city_postcode.trim(),
        email: draft.email.trim() || null,
        phone: draft.phone.trim() || null,
        nzbn: draft.nzbn.trim() || null,
        gst_number: draft.gst_number.trim() || null,
      })
    },
    onSuccess: async () => {
      await queryClient.invalidateQueries({ queryKey: BUSINESS_SETTINGS_QUERY_KEY })
      setFeedback({ kind: 'success', message: 'Business settings saved.' })
    },
    onError: (err) => {
      setFeedback({
        kind: 'error',
        message: queryErrorDetail(err).err?.message ?? 'Save failed.',
      })
    },
  })

  if (settingsQuery.isLoading || settingsQuery.isPending) {
    return (
      <div className="w-full min-w-0 py-4 sm:py-6">
        <PageHeader title="Business settings" description="Configuration" />
        <LoadingState message="Loading business settings…" />
      </div>
    )
  }

  if (settingsQuery.isError) {
    return (
      <div className="w-full min-w-0 py-4 sm:py-6">
        <PageHeader title="Business settings" description="Configuration" />
        <ErrorState
          title="Could not load business settings"
          error={settingsQuery.error}
          onRetry={() => void settingsQuery.refetch()}
        />
      </div>
    )
  }

  return (
    <div
      className="w-full min-w-0 py-4 sm:py-6"
      data-testid="admin-business-settings-page"
    >
      <PageHeader
        title="Business settings"
        description={
          'Buyer details used on every buyer-created tax invoice (contractor invoices).\n' +
          'Snapshotted onto each saved invoice — later changes do not affect existing invoices.'
        }
      />

      {missing.length > 0 ? (
        <div
          className="mb-4 rounded-md border border-amber-200 bg-amber-50 px-3 py-2 text-sm text-amber-900"
          role="status"
        >
          <strong className="font-semibold">Setup incomplete:</strong>{' '}
          Contractor invoices cannot be created until the following required fields
          are saved —{' '}
          {missing
            .map((k) => BUSINESS_SETTINGS_FIELD_LABELS[k] ?? String(k))
            .join(', ')}
          .
        </div>
      ) : null}

      {viewOnly ? (
        <div
          className="mb-4 rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-700"
          role="status"
        >
          You have <strong>View-only</strong> access to Business settings. Editing is disabled.
        </div>
      ) : null}

      {feedback ? (
        <div
          className={`mb-4 rounded-md border px-3 py-2 text-sm ${
            feedback.kind === 'success'
              ? 'border-emerald-200 bg-emerald-50 text-emerald-800'
              : 'border-rose-200 bg-rose-50 text-rose-800'
          }`}
          role="status"
        >
          {feedback.message}
        </div>
      ) : null}

      <form
        className="space-y-6 rounded-lg border border-slate-200 bg-white p-4 shadow-sm sm:p-6"
        onSubmit={(e) => {
          e.preventDefault()
          if (!dirty || saveMut.isPending || viewOnly) return
          setFeedback(null)
          saveMut.mutate()
        }}
      >
        <fieldset className="space-y-4">
          <legend className="text-sm font-semibold uppercase tracking-wide text-slate-500">
            Required
          </legend>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div className="sm:col-span-2">
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="bs_legal"
              >
                Legal business name *
              </label>
              <input
                id="bs_legal"
                type="text"
                value={draft.legal_business_name}
                onChange={(e) =>
                  setDraft((d) => ({ ...d, legal_business_name: e.target.value }))
                }
                className={inputClass()}
                disabled={viewOnly}
                placeholder="e.g. Corsa Wilde Limited"
              />
            </div>
            <div>
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="bs_street"
              >
                Street address *
              </label>
              <input
                id="bs_street"
                type="text"
                value={draft.street_address}
                onChange={(e) =>
                  setDraft((d) => ({ ...d, street_address: e.target.value }))
                }
                className={inputClass()}
                disabled={viewOnly}
              />
            </div>
            <div>
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="bs_suburb"
              >
                Suburb *
              </label>
              <input
                id="bs_suburb"
                type="text"
                value={draft.suburb}
                onChange={(e) => setDraft((d) => ({ ...d, suburb: e.target.value }))}
                className={inputClass()}
                disabled={viewOnly}
              />
            </div>
            <div className="sm:col-span-2">
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="bs_city"
              >
                City & postcode *
              </label>
              <input
                id="bs_city"
                type="text"
                value={draft.city_postcode}
                onChange={(e) =>
                  setDraft((d) => ({ ...d, city_postcode: e.target.value }))
                }
                className={inputClass()}
                disabled={viewOnly}
                placeholder="e.g. Auckland 0632"
              />
            </div>
          </div>
        </fieldset>

        <fieldset className="space-y-4 border-t border-slate-100 pt-4">
          <legend className="text-sm font-semibold uppercase tracking-wide text-slate-500">
            Optional
          </legend>
          <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
            <div>
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="bs_trading"
              >
                Trading name
              </label>
              <input
                id="bs_trading"
                type="text"
                value={draft.trading_name}
                onChange={(e) =>
                  setDraft((d) => ({ ...d, trading_name: e.target.value }))
                }
                className={inputClass()}
                disabled={viewOnly}
                placeholder="e.g. Oscar & Co"
              />
              <p className="mt-1 text-xs text-slate-500">
                Shown on the invoice as <em>Trading as …</em>.
              </p>
            </div>
            <div>
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="bs_email"
              >
                Email
              </label>
              <input
                id="bs_email"
                type="email"
                value={draft.email}
                onChange={(e) => setDraft((d) => ({ ...d, email: e.target.value }))}
                className={inputClass()}
                disabled={viewOnly}
              />
            </div>
            <div>
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="bs_phone"
              >
                Phone
              </label>
              <input
                id="bs_phone"
                type="tel"
                value={draft.phone}
                onChange={(e) => setDraft((d) => ({ ...d, phone: e.target.value }))}
                className={inputClass()}
                disabled={viewOnly}
              />
            </div>
            <div>
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="bs_nzbn"
              >
                NZBN
              </label>
              <input
                id="bs_nzbn"
                type="text"
                value={draft.nzbn}
                onChange={(e) => setDraft((d) => ({ ...d, nzbn: e.target.value }))}
                className={inputClass()}
                disabled={viewOnly}
              />
            </div>
            <div>
              <label
                className="block text-sm font-medium text-slate-700"
                htmlFor="bs_gst"
              >
                GST number
              </label>
              <input
                id="bs_gst"
                type="text"
                value={draft.gst_number}
                onChange={(e) =>
                  setDraft((d) => ({ ...d, gst_number: e.target.value }))
                }
                className={inputClass()}
                disabled={viewOnly}
              />
            </div>
          </div>
        </fieldset>

        {!viewOnly ? (
          <div className="flex items-center justify-end gap-2 border-t border-slate-100 pt-4">
            <button
              type="button"
              onClick={() => setDraft(rowToDraft(settingsQuery.data ?? null))}
              disabled={!dirty || saveMut.isPending}
              className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 disabled:opacity-50"
            >
              Discard changes
            </button>
            <button
              type="submit"
              disabled={!dirty || saveMut.isPending}
              className="rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700 disabled:opacity-50"
            >
              {saveMut.isPending ? 'Saving…' : 'Save changes'}
            </button>
          </div>
        ) : null}
      </form>
    </div>
  )
}
