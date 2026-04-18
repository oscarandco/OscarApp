import { type FormEvent, useEffect, useMemo, useState } from 'react'

import { ToggleField } from '@/features/admin/components/QuoteSettingsCard'
import {
  defaultExtraUnit,
  defaultNumericMultiplier,
  defaultSpecialExtraProduct,
  isExtraUnitPricing,
  isNumericPricing,
  isOptionBasedInput,
  isOptionBasedPricing,
  isRoleBasedPricing,
  isSpecialExtraProductPricing,
  QUOTE_INPUT_TYPES,
  QUOTE_PRICING_TYPES,
  QUOTE_ROLES,
  quoteInputTypeLabel,
  quotePricingTypeLabel,
  quoteRoleLabel,
  slugifyInternalKey,
  type ExtraUnitConfig,
  type NumericMultiplierConfig,
  type QuoteInputType,
  type QuotePricingType,
  type QuoteRole,
  type QuoteService,
  type QuoteServiceOption,
  type SpecialExtraProductConfig,
} from '@/features/admin/types/quoteConfiguration'

/** Form state — uses strings for numeric inputs to avoid NaN while typing. */
type DraftOption = {
  id: string
  label: string
  valueKey: string
  displayOrder: number
  active: boolean
  priceText: string
}

type Draft = {
  name: string
  internalKey: string
  active: boolean
  displayOrder: string
  helpText: string
  summaryLabelOverride: string

  inputType: QuoteInputType
  pricingType: QuotePricingType

  visibleRoles: Set<QuoteRole>

  options: DraftOption[]

  fixedPriceText: string
  rolePricesText: Partial<Record<QuoteRole, string>>

  numeric: NumericMultiplierConfig
  extraUnit: ExtraUnitConfig
  specialExtra: SpecialExtraProductConfig

  includeInQuoteSummary: boolean
  summaryGroupOverride: string
  adminNotes: string
}

export type QuoteServiceDrawerMode = 'create' | 'edit' | 'duplicate'

type QuoteServiceDrawerProps = {
  open: boolean
  mode: QuoteServiceDrawerMode
  sectionId: string
  existingService: QuoteService | null
  onClose: () => void
  onSubmit: (
    payload: Partial<QuoteService> & { name: string; sectionId: string },
    ctx: { mode: QuoteServiceDrawerMode; existingId: string | null },
  ) => void
  onArchive?: (service: QuoteService) => void
  onDelete?: (service: QuoteService) => void
  /**
   * Optional: the full flat list of services from the loaded quote
   * configuration. When provided, the "Link To Base Service" field on
   * `extra_unit_price` services renders as a dropdown of eligible base
   * services instead of a raw GUID text input. The dropdown still
   * stores `linkToBaseServiceId` as a service id — backend/storage
   * shape is unchanged. When this prop is omitted the drawer falls
   * back to the legacy text input, so older call sites keep working.
   */
  allServices?: readonly QuoteService[]
}

function emptyDraft(): Draft {
  return {
    name: '',
    internalKey: '',
    active: true,
    displayOrder: '',
    helpText: '',
    summaryLabelOverride: '',
    inputType: 'checkbox',
    pricingType: 'fixed_price',
    visibleRoles: new Set<QuoteRole>(),
    options: [],
    fixedPriceText: '',
    rolePricesText: {},
    numeric: defaultNumericMultiplier(),
    extraUnit: defaultExtraUnit(),
    specialExtra: defaultSpecialExtraProduct(),
    includeInQuoteSummary: true,
    summaryGroupOverride: '',
    adminNotes: '',
  }
}

function draftFromService(s: QuoteService, mode: QuoteServiceDrawerMode): Draft {
  const rolePricesText: Partial<Record<QuoteRole, string>> = {}
  for (const r of QUOTE_ROLES) {
    const v = s.rolePrices[r]
    rolePricesText[r] = v == null ? '' : String(v)
  }
  return {
    name: mode === 'duplicate' ? `${s.name} (copy)` : s.name,
    internalKey:
      mode === 'duplicate' && s.internalKey
        ? `${s.internalKey}_copy`
        : (s.internalKey ?? ''),
    active: s.active,
    displayOrder: String(s.displayOrder),
    helpText: s.helpText ?? '',
    summaryLabelOverride: s.summaryLabelOverride ?? '',
    inputType: s.inputType,
    pricingType: s.pricingType,
    visibleRoles: new Set(s.visibleRoles),
    options: s.options.map((o) => ({
      id: o.id,
      label: o.label,
      valueKey: o.valueKey,
      displayOrder: o.displayOrder,
      active: o.active,
      priceText: o.price == null ? '' : String(o.price),
    })),
    fixedPriceText: s.fixedPrice == null ? '' : String(s.fixedPrice),
    rolePricesText,
    numeric: s.numeric ?? defaultNumericMultiplier(),
    extraUnit: s.extraUnit ?? defaultExtraUnit(),
    specialExtra: s.specialExtra ?? defaultSpecialExtraProduct(),
    includeInQuoteSummary: s.includeInQuoteSummary,
    summaryGroupOverride: s.summaryGroupOverride ?? '',
    adminNotes: s.adminNotes ?? '',
  }
}

function parseNumberOrNull(text: string): number | null {
  const t = text.trim()
  if (t === '') return null
  const n = Number(t)
  return Number.isFinite(n) ? n : null
}

function genDraftOptionId(): string {
  return `opt_draft_${Math.random().toString(36).slice(2, 10)}`
}

type ErrorMap = Partial<{
  name: string
  displayOrder: string
  visibleRoles: string
  options: string
  numeric: string
  form: string
}>

export function QuoteServiceDrawer({
  open,
  mode,
  sectionId,
  existingService,
  onClose,
  onSubmit,
  onArchive,
  onDelete,
  allServices,
}: QuoteServiceDrawerProps) {
  const [draft, setDraft] = useState<Draft>(() =>
    existingService ? draftFromService(existingService, mode) : emptyDraft(),
  )
  const [errors, setErrors] = useState<ErrorMap>({})

  useEffect(() => {
    if (!open) return
    setErrors({})
    setDraft(
      existingService ? draftFromService(existingService, mode) : emptyDraft(),
    )
  }, [open, mode, existingService])

  useEffect(() => {
    if (!open) return
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') onClose()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [open, onClose])

  const roleBased = isRoleBasedPricing(draft.pricingType)
  const optionBasedInput = isOptionBasedInput(draft.inputType)
  const optionBasedPricing = isOptionBasedPricing(draft.pricingType)
  const showOptionsSection = optionBasedInput || optionBasedPricing
  const showNumeric = isNumericPricing(draft.pricingType)
  const showExtraUnit = isExtraUnitPricing(draft.pricingType)
  const showSpecialExtra = isSpecialExtraProductPricing(draft.pricingType)

  function patch(p: Partial<Draft>) {
    setDraft((prev) => ({ ...prev, ...p }))
  }

  function patchOption(id: string, p: Partial<DraftOption>) {
    setDraft((prev) => ({
      ...prev,
      options: prev.options.map((o) => (o.id === id ? { ...o, ...p } : o)),
    }))
  }

  function addOption() {
    setDraft((prev) => {
      const nextOrder =
        prev.options.length === 0
          ? 1
          : Math.max(...prev.options.map((o) => o.displayOrder)) + 1
      return {
        ...prev,
        options: [
          ...prev.options,
          {
            id: genDraftOptionId(),
            label: '',
            valueKey: '',
            displayOrder: nextOrder,
            active: true,
            priceText: '',
          },
        ],
      }
    })
  }

  function removeOption(id: string) {
    setDraft((prev) => ({
      ...prev,
      options: prev.options.filter((o) => o.id !== id),
    }))
  }

  function moveOption(id: string, direction: 'up' | 'down') {
    setDraft((prev) => {
      const sorted = [...prev.options].sort(
        (a, b) => a.displayOrder - b.displayOrder,
      )
      const idx = sorted.findIndex((o) => o.id === id)
      const swap = direction === 'up' ? idx - 1 : idx + 1
      if (idx === -1 || swap < 0 || swap >= sorted.length) return prev
      const a = sorted[idx]
      const b = sorted[swap]
      const ao = a.displayOrder
      const bo = b.displayOrder
      return {
        ...prev,
        options: prev.options.map((o) => {
          if (o.id === a.id) return { ...o, displayOrder: bo }
          if (o.id === b.id) return { ...o, displayOrder: ao }
          return o
        }),
      }
    })
  }

  function handleInputTypeChange(next: QuoteInputType) {
    setDraft((prev) => {
      let pricing = prev.pricingType
      if (next === 'role_radio') pricing = 'role_price'
      else if (next === 'option_radio' || next === 'dropdown')
        pricing = 'option_price'
      else if (next === 'numeric_input') pricing = 'numeric_multiplier'
      else if (next === 'extra_units') pricing = 'extra_unit_price'
      else if (next === 'special_extra_product') pricing = 'special_extra_product'
      else if (next === 'checkbox' && pricing === 'role_price') pricing = 'fixed_price'
      return { ...prev, inputType: next, pricingType: pricing }
    })
  }

  function buildPayload(): {
    payload: (Partial<QuoteService> & { name: string; sectionId: string }) | null
    errors: ErrorMap
  } {
    const errs: ErrorMap = {}
    const name = draft.name.trim()
    if (name === '') errs.name = 'Service Name is required.'

    const displayOrderNum = Number(draft.displayOrder)
    if (draft.displayOrder !== '' && !Number.isFinite(displayOrderNum)) {
      errs.displayOrder = 'Display Order must be a number.'
    }

    if (roleBased && draft.visibleRoles.size === 0) {
      errs.visibleRoles =
        'Role-based services must have at least one visible role.'
    }

    if (optionBasedInput) {
      const activeOptions = draft.options.filter(
        (o) => o.active && o.label.trim() !== '',
      )
      if (activeOptions.length === 0) {
        errs.options =
          'Option-based services must have at least one active option with a label.'
      }
    }

    if (showNumeric) {
      if (!Number.isFinite(draft.numeric.pricePerUnit)) {
        errs.numeric = 'Numeric multiplier services need a price per unit.'
      } else if (draft.numeric.min > draft.numeric.max) {
        errs.numeric = 'Numeric min must be ≤ max.'
      }
    }

    if (Object.keys(errs).length > 0) {
      errs.form = 'Please fix the highlighted field(s) before saving.'
      return { payload: null, errors: errs }
    }

    const internalKey =
      draft.internalKey.trim() !== ''
        ? draft.internalKey.trim()
        : slugifyInternalKey(name)

    const options: QuoteServiceOption[] = draft.options
      .filter((o) => o.label.trim() !== '' || optionBasedPricing)
      .map((o) => ({
        id: o.id,
        label: o.label.trim(),
        valueKey:
          o.valueKey.trim() !== ''
            ? o.valueKey.trim()
            : slugifyInternalKey(o.label),
        displayOrder: o.displayOrder,
        active: o.active,
        price: optionBasedPricing ? parseNumberOrNull(o.priceText) : null,
      }))

    const rolePrices: Partial<Record<QuoteRole, number | null>> = {}
    if (roleBased) {
      for (const r of QUOTE_ROLES) {
        if (draft.visibleRoles.has(r)) {
          rolePrices[r] = parseNumberOrNull(draft.rolePricesText[r] ?? '')
        }
      }
    }

    const payload: Partial<QuoteService> & { name: string; sectionId: string } = {
      sectionId,
      name,
      internalKey,
      active: draft.active,
      displayOrder: draft.displayOrder === '' ? undefined : Math.trunc(displayOrderNum),
      helpText: draft.helpText.trim() === '' ? null : draft.helpText.trim(),
      summaryLabelOverride:
        draft.summaryLabelOverride.trim() === ''
          ? null
          : draft.summaryLabelOverride.trim(),
      inputType: draft.inputType,
      pricingType: draft.pricingType,
      visibleRoles: roleBased
        ? QUOTE_ROLES.filter((r) => draft.visibleRoles.has(r))
        : [],
      options,
      fixedPrice:
        draft.pricingType === 'fixed_price'
          ? parseNumberOrNull(draft.fixedPriceText)
          : null,
      rolePrices,
      numeric: showNumeric ? { ...draft.numeric } : null,
      extraUnit: showExtraUnit ? { ...draft.extraUnit } : null,
      specialExtra: showSpecialExtra ? { ...draft.specialExtra } : null,
      includeInQuoteSummary: draft.includeInQuoteSummary,
      summaryGroupOverride:
        draft.summaryGroupOverride.trim() === ''
          ? null
          : draft.summaryGroupOverride.trim(),
      adminNotes: draft.adminNotes.trim() === '' ? null : draft.adminNotes.trim(),
    }

    return { payload, errors: errs }
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault()
    const { payload, errors: errs } = buildPayload()
    setErrors(errs)
    if (!payload) return
    const existingId =
      mode === 'edit' && existingService ? existingService.id : null
    onSubmit(payload, { mode, existingId })
    onClose()
  }

  const title = useMemo(() => {
    if (mode === 'create') return 'Add Service'
    if (mode === 'duplicate') return 'Duplicate Service'
    return 'Edit Service'
  }, [mode])

  const canDelete =
    mode === 'edit' &&
    !!existingService &&
    !existingService.usedInSavedQuotes &&
    !!onDelete

  if (!open) return null

  return (
    <div
      className="fixed inset-0 z-50 flex justify-end bg-black/40"
      role="dialog"
      aria-modal="true"
      aria-labelledby="service-drawer-title"
      onClick={onClose}
    >
      <form
        onSubmit={handleSubmit}
        className="flex h-full w-full max-w-3xl flex-col overflow-hidden border-l border-slate-200 bg-white shadow-xl lg:max-w-4xl"
        data-testid="quote-service-drawer"
        onClick={(e) => e.stopPropagation()}
      >
        <header className="flex shrink-0 items-center justify-between border-b border-slate-200 bg-white px-5 py-3">
          <div>
            <h2
              id="service-drawer-title"
              className="text-lg font-semibold text-slate-900"
            >
              {title}
            </h2>
            <p className="text-xs text-slate-500">
              {quoteInputTypeLabel(draft.inputType)} ·{' '}
              {quotePricingTypeLabel(draft.pricingType)}
            </p>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-md border border-slate-200 bg-white px-2 py-1 text-sm font-medium text-slate-700 hover:bg-slate-50"
            aria-label="Close drawer"
          >
            Close
          </button>
        </header>

        <div className="flex-1 overflow-y-auto bg-slate-50/40 px-5 py-5">
          <Block title="A. Basic" description="Name, identity, and ordering.">
            <div className="grid gap-3 sm:grid-cols-2">
              <TextField
                id="svc-name"
                label="Service Name"
                required
                value={draft.name}
                onChange={(v) => patch({ name: v })}
                error={errors.name}
                testId="svc-name"
              />
              <TextField
                id="svc-internal-key"
                label="Internal Key"
                value={draft.internalKey}
                onChange={(v) => patch({ internalKey: v })}
                placeholder="Auto-slug from name if empty"
                testId="svc-internal-key"
              />
              <TextField
                id="svc-display-order"
                label="Display Order"
                value={draft.displayOrder}
                onChange={(v) => patch({ displayOrder: v })}
                type="number"
                error={errors.displayOrder}
                testId="svc-display-order"
              />
              <ToggleField
                id="svc-active"
                label="Active"
                checked={draft.active}
                onChange={(v) => patch({ active: v })}
                testId="svc-active"
              />
              <TextField
                id="svc-help-text"
                label="Help Text"
                value={draft.helpText}
                onChange={(v) => patch({ helpText: v })}
                testId="svc-help-text"
              />
              <TextField
                id="svc-summary-override"
                label="Summary Label Override"
                value={draft.summaryLabelOverride}
                onChange={(v) => patch({ summaryLabelOverride: v })}
                testId="svc-summary-override"
              />
            </div>
          </Block>

          <Block
            title="B & C. Input and Pricing"
            description="Changing the input type auto-selects a compatible pricing type."
          >
            <div className="grid gap-3 sm:grid-cols-2">
              <SelectField
                id="svc-input-type"
                label="Input Type"
                value={draft.inputType}
                onChange={(v) => handleInputTypeChange(v as QuoteInputType)}
                options={QUOTE_INPUT_TYPES.map((t) => ({
                  value: t,
                  label: quoteInputTypeLabel(t),
                }))}
                testId="svc-input-type"
              />
              <SelectField
                id="svc-pricing-type"
                label="Pricing Type"
                value={draft.pricingType}
                onChange={(v) => patch({ pricingType: v as QuotePricingType })}
                options={QUOTE_PRICING_TYPES.map((p) => ({
                  value: p,
                  label: quotePricingTypeLabel(p),
                }))}
                testId="svc-pricing-type"
              />
            </div>
          </Block>

          {roleBased ? (
            <Block
              title="D. Visible Roles"
              description="At least one role is required for role-based services."
              errorText={errors.visibleRoles}
            >
              <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
                {QUOTE_ROLES.map((role) => {
                  const checked = draft.visibleRoles.has(role)
                  return (
                    <label
                      key={role}
                      className={`inline-flex cursor-pointer items-center gap-2 rounded-md border px-3 py-2 text-sm transition ${
                        checked
                          ? 'border-violet-300 bg-violet-50 text-violet-900'
                          : 'border-slate-200 bg-white text-slate-800 hover:bg-slate-50'
                      }`}
                    >
                      <input
                        type="checkbox"
                        checked={checked}
                        onChange={(e) => {
                          setDraft((prev) => {
                            const next = new Set(prev.visibleRoles)
                            if (e.target.checked) next.add(role)
                            else next.delete(role)
                            return { ...prev, visibleRoles: next }
                          })
                        }}
                        className="h-4 w-4 rounded border-slate-300 text-violet-600 focus:ring-violet-500"
                        data-testid={`svc-role-${role.toLowerCase()}`}
                      />
                      {quoteRoleLabel(role)}
                    </label>
                  )
                })}
              </div>
            </Block>
          ) : null}

          {showOptionsSection ? (
            <Block
              title="E. Options"
              description={
                optionBasedPricing
                  ? 'Prices are per option. Inactive options are hidden on the quote.'
                  : 'Labels shown on the stylist quote. Inactive options are hidden.'
              }
              errorText={errors.options}
            >
              <OptionsEditor
                options={[...draft.options].sort(
                  (a, b) => a.displayOrder - b.displayOrder,
                )}
                withPrice={optionBasedPricing}
                onAdd={addOption}
                onRemove={removeOption}
                onMove={moveOption}
                onChange={patchOption}
              />
            </Block>
          ) : null}

          <Block
            title="F. Price Setup"
            description="Fields below match the selected pricing type."
            errorText={errors.numeric}
          >
            <PriceSetup
              draft={draft}
              existingServiceId={existingService?.id ?? null}
              allServices={allServices}
              onPatch={patch}
              onPatchNumeric={(np) =>
                setDraft((prev) => ({ ...prev, numeric: { ...prev.numeric, ...np } }))
              }
              onPatchExtraUnit={(np) =>
                setDraft((prev) => ({
                  ...prev,
                  extraUnit: { ...prev.extraUnit, ...np },
                }))
              }
              onPatchSpecial={(np) =>
                setDraft((prev) => ({
                  ...prev,
                  specialExtra: { ...prev.specialExtra, ...np },
                }))
              }
            />
          </Block>

          <Block
            title="G. Summary / Behaviour"
            description="Leave blank to use the section summary. Use only if this service should total under a different group."
          >
            <div className="grid gap-3 sm:grid-cols-2">
              <ToggleField
                id="svc-include-in-summary"
                label="Include In Quote Summary"
                checked={draft.includeInQuoteSummary}
                onChange={(v) => patch({ includeInQuoteSummary: v })}
                testId="svc-include-in-summary"
              />
              <TextField
                id="svc-summary-group"
                label="Summary Group Override"
                value={draft.summaryGroupOverride}
                onChange={(v) => patch({ summaryGroupOverride: v })}
                testId="svc-summary-group"
              />
              <TextAreaField
                id="svc-admin-notes"
                label="Admin Notes"
                value={draft.adminNotes}
                onChange={(v) => patch({ adminNotes: v })}
                className="sm:col-span-2"
                testId="svc-admin-notes"
              />
            </div>
          </Block>

          {existingService ? (
            <Block title="H. Usage" description="Read-only metadata.">
              <dl className="grid gap-3 text-sm text-slate-700 sm:grid-cols-3">
                <div>
                  <dt className="text-xs uppercase tracking-wide text-slate-500">
                    Used In Saved Quotes
                  </dt>
                  <dd className="mt-0.5">
                    {existingService.usedInSavedQuotes ? 'Yes' : 'No'}
                  </dd>
                </div>
                <div>
                  <dt className="text-xs uppercase tracking-wide text-slate-500">
                    Created
                  </dt>
                  <dd className="mt-0.5 font-mono text-xs text-slate-600">
                    {existingService.createdAt}
                  </dd>
                </div>
                <div>
                  <dt className="text-xs uppercase tracking-wide text-slate-500">
                    Updated
                  </dt>
                  <dd className="mt-0.5 font-mono text-xs text-slate-600">
                    {existingService.updatedAt}
                  </dd>
                </div>
              </dl>
            </Block>
          ) : null}
        </div>

        {errors.form ? (
          <p
            className="shrink-0 border-t border-rose-200 bg-rose-50 px-5 py-2 text-sm text-rose-700"
            role="alert"
            data-testid="quote-service-drawer-error"
          >
            {errors.form}
          </p>
        ) : null}

        <footer className="flex shrink-0 items-center justify-between gap-2 border-t border-slate-200 bg-white px-5 py-3">
          <div className="flex items-center gap-2">
            {mode === 'edit' && existingService && onArchive ? (
              <button
                type="button"
                onClick={() => onArchive(existingService)}
                className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
                data-testid="quote-service-drawer-archive"
              >
                {existingService.active ? 'Archive Service' : 'Unarchive Service'}
              </button>
            ) : null}
            {canDelete && existingService ? (
              <button
                type="button"
                onClick={() => onDelete?.(existingService)}
                className="rounded-md border border-rose-200 bg-white px-3 py-2 text-sm font-medium text-rose-700 shadow-sm hover:bg-rose-50"
                data-testid="quote-service-drawer-delete"
              >
                Delete Service
              </button>
            ) : null}
          </div>
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={onClose}
              className="rounded-md border border-slate-200 bg-white px-3 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50"
            >
              Cancel
            </button>
            <button
              type="submit"
              className="rounded-md bg-violet-600 px-3 py-2 text-sm font-medium text-white shadow-sm hover:bg-violet-700 focus:outline-none focus-visible:ring-2 focus-visible:ring-violet-500 focus-visible:ring-offset-1"
              data-testid="quote-service-drawer-save"
            >
              Save Service
            </button>
          </div>
        </footer>
      </form>
    </div>
  )
}

function Block({
  title,
  description,
  errorText,
  children,
}: {
  title: string
  description?: string
  errorText?: string
  children: React.ReactNode
}) {
  return (
    <section className="mb-4 rounded-lg border border-slate-200 bg-white p-4 shadow-sm">
      <div className="mb-3">
        <h3 className="text-sm font-semibold text-slate-800">{title}</h3>
        {description ? (
          <p className="mt-0.5 text-xs text-slate-500">{description}</p>
        ) : null}
      </div>
      {children}
      {errorText ? (
        <p
          className="mt-3 rounded-md border border-rose-200 bg-rose-50 px-3 py-2 text-xs text-rose-700"
          role="alert"
        >
          {errorText}
        </p>
      ) : null}
    </section>
  )
}

/**
 * Tailwind class fragments that apply the shared "editable value" treatment to
 * price / numeric-config inputs across the Quote Service drawer.
 *
 * Design intent: a single darker forest-emerald tone (emerald-700) is used
 * consistently for the label, the input border, the input text, and the focus
 * ring, so editable value fields read clearly as "this is the number to
 * change". The input background stays white — no tinted fill — and the border
 * is 2px (vs 1px on descriptive/default fields) so the value boxes stand
 * apart without being loud.
 *
 * Error styling still wins over the value variant and keeps its own 1px rose
 * border.
 */
const valueLabelClass = 'block text-sm font-semibold text-emerald-700'
const valueInputClass =
  'border-2 border-emerald-700 bg-white text-emerald-700 font-semibold placeholder:text-emerald-700/40 focus:border-emerald-700 focus:ring-emerald-700'
const defaultLabelClass = 'block text-sm font-medium text-slate-700'
const defaultInputClass = 'border border-slate-200 focus:ring-violet-500'

function TextField({
  id,
  label,
  value,
  onChange,
  required,
  placeholder,
  type,
  testId,
  className,
  error,
  variant,
}: {
  id: string
  label: string
  value: string
  onChange: (v: string) => void
  required?: boolean
  placeholder?: string
  type?: string
  testId?: string
  className?: string
  error?: string
  /** 'value' applies the shared blue treatment for editable price/config values. */
  variant?: 'default' | 'value'
}) {
  const isValue = variant === 'value'
  const stateClass = error
    ? 'border border-rose-300 focus:ring-rose-500'
    : isValue
      ? valueInputClass
      : defaultInputClass
  return (
    <div className={className}>
      <label
        htmlFor={id}
        className={isValue ? valueLabelClass : defaultLabelClass}
      >
        {label}
        {required ? <span className="text-rose-600"> *</span> : null}
      </label>
      <input
        id={id}
        type={type ?? 'text'}
        required={required}
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        data-testid={testId}
        aria-invalid={error ? true : undefined}
        className={`mt-1 w-full rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 ${stateClass}`}
      />
      {error ? (
        <p className="mt-1 text-xs text-rose-700" role="alert">
          {error}
        </p>
      ) : null}
    </div>
  )
}

function TextAreaField({
  id,
  label,
  value,
  onChange,
  className,
  testId,
}: {
  id: string
  label: string
  value: string
  onChange: (v: string) => void
  className?: string
  testId?: string
}) {
  return (
    <div className={className}>
      <label htmlFor={id} className="block text-sm font-medium text-slate-700">
        {label}
      </label>
      <textarea
        id={id}
        value={value}
        rows={3}
        onChange={(e) => onChange(e.target.value)}
        data-testid={testId}
        className="mt-1 w-full rounded-md border border-slate-200 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
      />
    </div>
  )
}

function SelectField({
  id,
  label,
  value,
  onChange,
  options,
  testId,
}: {
  id: string
  label: string
  value: string
  onChange: (v: string) => void
  options: { value: string; label: string }[]
  testId?: string
}) {
  return (
    <div>
      <label htmlFor={id} className="block text-sm font-medium text-slate-700">
        {label}
      </label>
      <select
        id={id}
        value={value}
        onChange={(e) => onChange(e.target.value)}
        data-testid={testId}
        className="mt-1 w-full rounded-md border border-slate-200 bg-white px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
      >
        {options.map((o) => (
          <option key={o.value} value={o.value}>
            {o.label}
          </option>
        ))}
      </select>
    </div>
  )
}

function OptionsEditor({
  options,
  withPrice,
  onAdd,
  onRemove,
  onMove,
  onChange,
}: {
  options: DraftOption[]
  withPrice: boolean
  onAdd: () => void
  onRemove: (id: string) => void
  onMove: (id: string, direction: 'up' | 'down') => void
  onChange: (id: string, p: Partial<DraftOption>) => void
}) {
  return (
    <div>
      <div className="mb-2 flex items-center justify-between gap-2">
        <p className="text-xs text-slate-500">
          Examples: Single (3g) / Double (6g) · 1/2, 3/4, Full · 1, 2, 3 · 10 pcs, 30 pcs.
        </p>
        <button
          type="button"
          onClick={onAdd}
          className="rounded-md border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 shadow-sm hover:bg-slate-50"
          data-testid="svc-option-add"
        >
          Add Option
        </button>
      </div>
      {options.length === 0 ? (
        <p className="rounded-md border border-dashed border-slate-200 bg-slate-50 px-3 py-4 text-center text-sm text-slate-500">
          No options yet. Click <span className="font-medium">Add Option</span> above.
        </p>
      ) : (
        <div className="space-y-2">
          {options.map((opt, idx) => (
            <div
              key={opt.id}
              className="grid grid-cols-12 gap-2 rounded-md border border-slate-200 bg-white p-2"
              data-testid={`svc-option-row-${opt.id}`}
            >
              <input
                className="col-span-4 rounded-md border border-slate-200 px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
                placeholder="Label"
                value={opt.label}
                onChange={(e) => onChange(opt.id, { label: e.target.value })}
              />
              <input
                className="col-span-3 rounded-md border border-slate-200 px-2 py-1 text-sm focus:outline-none focus:ring-2 focus:ring-violet-500"
                placeholder="Value Key"
                value={opt.valueKey}
                onChange={(e) => onChange(opt.id, { valueKey: e.target.value })}
              />
              {withPrice ? (
                <input
                  className="col-span-2 rounded-md border-2 border-emerald-700 bg-white px-2 py-1 text-sm font-semibold text-emerald-700 placeholder:text-emerald-700/40 focus:border-emerald-700 focus:outline-none focus:ring-2 focus:ring-emerald-700"
                  placeholder="Price"
                  type="number"
                  value={opt.priceText}
                  onChange={(e) =>
                    onChange(opt.id, { priceText: e.target.value })
                  }
                />
              ) : (
                <div className="col-span-2" />
              )}
              <label
                className="col-span-1 inline-flex items-center justify-center"
                title="Active"
              >
                <input
                  type="checkbox"
                  checked={opt.active}
                  onChange={(e) =>
                    onChange(opt.id, { active: e.target.checked })
                  }
                  className="h-4 w-4 rounded border-slate-300 text-violet-600 focus:ring-violet-500"
                />
              </label>
              <div className="col-span-2 flex items-center justify-end gap-1">
                <button
                  type="button"
                  onClick={() => onMove(opt.id, 'up')}
                  disabled={idx === 0}
                  className="rounded-md border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-40"
                  title={idx === 0 ? 'Already at the top' : 'Move up'}
                  aria-label="Move option up"
                >
                  ↑
                </button>
                <button
                  type="button"
                  onClick={() => onMove(opt.id, 'down')}
                  disabled={idx === options.length - 1}
                  className="rounded-md border border-slate-200 bg-white px-2 py-1 text-xs font-medium text-slate-700 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-40"
                  title={
                    idx === options.length - 1
                      ? 'Already at the bottom'
                      : 'Move down'
                  }
                  aria-label="Move option down"
                >
                  ↓
                </button>
                <button
                  type="button"
                  onClick={() => onRemove(opt.id)}
                  className="rounded-md border border-rose-200 bg-white px-2 py-1 text-xs font-medium text-rose-700 hover:bg-rose-50"
                  title="Remove option"
                  aria-label="Remove option"
                >
                  ×
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}

function PriceSetup({
  draft,
  existingServiceId,
  allServices,
  onPatch,
  onPatchNumeric,
  onPatchExtraUnit,
  onPatchSpecial,
}: {
  draft: Draft
  existingServiceId: string | null
  allServices: readonly QuoteService[] | undefined
  onPatch: (p: Partial<Draft>) => void
  onPatchNumeric: (p: Partial<NumericMultiplierConfig>) => void
  onPatchExtraUnit: (p: Partial<ExtraUnitConfig>) => void
  onPatchSpecial: (p: Partial<SpecialExtraProductConfig>) => void
}) {
  switch (draft.pricingType) {
    case 'fixed_price':
      return (
        <div className="grid gap-3 sm:grid-cols-2">
          <TextField
            id="svc-fixed-price"
            label="Price"
            value={draft.fixedPriceText}
            onChange={(v) => onPatch({ fixedPriceText: v })}
            type="number"
            testId="svc-fixed-price"
            variant="value"
          />
        </div>
      )
    case 'role_price':
      return (
        <div className="grid grid-cols-2 gap-3 sm:grid-cols-4">
          {QUOTE_ROLES.map((role) =>
            draft.visibleRoles.has(role) ? (
              <TextField
                key={role}
                id={`svc-role-price-${role}`}
                label={`${quoteRoleLabel(role)} Price`}
                value={draft.rolePricesText[role] ?? ''}
                onChange={(v) =>
                  onPatch({
                    rolePricesText: { ...draft.rolePricesText, [role]: v },
                  })
                }
                type="number"
                testId={`svc-role-price-${role.toLowerCase()}`}
                variant="value"
              />
            ) : null,
          )}
          {draft.visibleRoles.size === 0 ? (
            <p className="col-span-full text-xs text-slate-500">
              Select one or more visible roles above to configure role prices.
            </p>
          ) : null}
        </div>
      )
    case 'option_price':
      return (
        <p className="rounded-md bg-slate-50 px-3 py-2 text-sm text-slate-600 ring-1 ring-slate-200">
          Prices for option-priced services are edited inline in the Options list above.
        </p>
      )
    case 'numeric_multiplier':
      return (
        <div className="grid gap-3 sm:grid-cols-2">
          <TextField
            id="svc-num-unit-label"
            label="Unit Label"
            value={draft.numeric.unitLabel}
            onChange={(v) => onPatchNumeric({ unitLabel: v })}
          />
          <TextField
            id="svc-num-price"
            label="Price Per Unit"
            type="number"
            value={String(draft.numeric.pricePerUnit)}
            onChange={(v) =>
              onPatchNumeric({ pricePerUnit: parseNumberOrNull(v) ?? 0 })
            }
            variant="value"
          />
          <TextField
            id="svc-num-min"
            label="Min Value"
            type="number"
            value={String(draft.numeric.min)}
            onChange={(v) => onPatchNumeric({ min: parseNumberOrNull(v) ?? 0 })}
            variant="value"
          />
          <TextField
            id="svc-num-max"
            label="Max Value"
            type="number"
            value={String(draft.numeric.max)}
            onChange={(v) => onPatchNumeric({ max: parseNumberOrNull(v) ?? 0 })}
            variant="value"
          />
          <TextField
            id="svc-num-step"
            label="Step"
            type="number"
            value={String(draft.numeric.step)}
            onChange={(v) =>
              onPatchNumeric({ step: parseNumberOrNull(v) ?? 1 })
            }
            variant="value"
          />
          <TextField
            id="svc-num-default"
            label="Default Value"
            type="number"
            value={String(draft.numeric.defaultValue)}
            onChange={(v) =>
              onPatchNumeric({ defaultValue: parseNumberOrNull(v) ?? 0 })
            }
            variant="value"
          />
          <TextField
            id="svc-num-round-to"
            label="Round To (optional)"
            type="number"
            value={
              draft.numeric.roundTo == null ? '' : String(draft.numeric.roundTo)
            }
            onChange={(v) => onPatchNumeric({ roundTo: parseNumberOrNull(v) })}
            variant="value"
          />
          <TextField
            id="svc-num-min-charge"
            label="Min Charge (optional)"
            type="number"
            value={
              draft.numeric.minCharge == null
                ? ''
                : String(draft.numeric.minCharge)
            }
            onChange={(v) => onPatchNumeric({ minCharge: parseNumberOrNull(v) })}
            variant="value"
          />
        </div>
      )
    case 'extra_unit_price':
      return (
        <div className="grid gap-3 sm:grid-cols-2">
          <TextField
            id="svc-extra-base-label"
            label="Base Included Amount Label (optional)"
            value={draft.extraUnit.baseIncludedAmountLabel ?? ''}
            onChange={(v) =>
              onPatchExtraUnit({
                baseIncludedAmountLabel: v === '' ? null : v,
              })
            }
          />
          <TextField
            id="svc-extra-label"
            label="Extra Label"
            value={draft.extraUnit.extraLabel}
            onChange={(v) => onPatchExtraUnit({ extraLabel: v })}
          />
          <TextField
            id="svc-extra-suffix"
            label="Extra Unit Display Suffix (optional)"
            value={draft.extraUnit.extraUnitDisplaySuffix ?? ''}
            onChange={(v) =>
              onPatchExtraUnit({
                extraUnitDisplaySuffix: v === '' ? null : v,
              })
            }
          />
          <TextField
            id="svc-extra-price"
            label="Price Per Extra Unit"
            type="number"
            value={String(draft.extraUnit.pricePerExtraUnit)}
            onChange={(v) =>
              onPatchExtraUnit({
                pricePerExtraUnit: parseNumberOrNull(v) ?? 0,
              })
            }
            variant="value"
          />
          <TextField
            id="svc-extra-max"
            label="Max Extras"
            type="number"
            value={String(draft.extraUnit.maxExtras)}
            onChange={(v) =>
              onPatchExtraUnit({ maxExtras: parseNumberOrNull(v) ?? 0 })
            }
            variant="value"
          />
          <div>
            <label className="block text-sm font-medium text-slate-700">
              Option Style
            </label>
            <input
              disabled
              value="radio_1_to_n"
              className="mt-1 w-full rounded-md border border-slate-200 bg-slate-50 px-3 py-2 text-sm text-slate-600"
            />
            <p className="mt-1 text-xs text-slate-500">Locked for MVP.</p>
          </div>
          <BaseServiceLinkField
            currentValue={draft.extraUnit.linkToBaseServiceId}
            existingServiceId={existingServiceId}
            allServices={allServices}
            onChange={(v) =>
              onPatchExtraUnit({ linkToBaseServiceId: v })
            }
          />
        </div>
      )
    case 'special_extra_product': {
      // Special Extra Product renders as a single standalone row on the
      // Guest Quote page: one numeric grams input, one per-unit price.
      // The legacy `numberOfRows` / `maxUnitsPerRow` fields are no
      // longer exposed here — they remain on the draft/config only so
      // existing saved rows round-trip unchanged through the admin save
      // path. The preview below is intentionally a one-unit example,
      // matching what the Guest Quote page will show.
      const cfg = draft.specialExtra
      const sample = cfg.blueSummaryLabelTemplate
        .replace('{units}', '1')
        .replace('{grams}', String(cfg.gramsPerUnit))
        .replace('{minutes}', String(cfg.minutesPerUnit))
      return (
        <div className="grid gap-3 sm:grid-cols-2">
          <TextField
            id="svc-sep-price-per-unit"
            label="Price Per Unit"
            type="number"
            value={String(cfg.pricePerUnit)}
            onChange={(v) =>
              onPatchSpecial({ pricePerUnit: parseNumberOrNull(v) ?? 0 })
            }
            variant="value"
          />
          <TextField
            id="svc-sep-grams"
            label="Grams Per Unit"
            type="number"
            value={String(cfg.gramsPerUnit)}
            onChange={(v) =>
              onPatchSpecial({ gramsPerUnit: parseNumberOrNull(v) ?? 0 })
            }
            variant="value"
          />
          <TextField
            id="svc-sep-minutes"
            label="Minutes Per Unit"
            type="number"
            value={String(cfg.minutesPerUnit)}
            onChange={(v) =>
              onPatchSpecial({ minutesPerUnit: parseNumberOrNull(v) ?? 0 })
            }
            variant="value"
          />
          <TextField
            id="svc-sep-template"
            label="Blue Summary Label Template"
            value={cfg.blueSummaryLabelTemplate}
            onChange={(v) => onPatchSpecial({ blueSummaryLabelTemplate: v })}
            placeholder="{units} units / {grams} grams or {minutes} mins"
          />
          <div className="rounded-md border border-sky-200 bg-sky-50 px-3 py-2 text-xs text-sky-800 sm:col-span-2">
            <span className="font-medium">Preview (one unit):</span> {sample}
          </div>
        </div>
      )
    }
    default:
      return null
  }
}

/**
 * Dropdown for the `extra_unit_price` "Link To Base Service" field.
 *
 * Backend/storage shape is unchanged — the field still stores a
 * `link_to_base_service_id` GUID. This component simply swaps the
 * admin-facing UX: instead of typing a GUID, the admin picks from a
 * filtered list of eligible base services.
 *
 * Eligibility (frontend-only, computed from the loaded config):
 *   1. Must not be the current service itself (prevent self-link).
 *   2. Must not itself be an `extra_units` input row (those are
 *      child-style rows; they cannot act as a base).
 *   3. Must not already carry a `linkToBaseServiceId` of its own (a
 *      service that links to another service is already a child — it
 *      cannot also be a parent).
 *   4. Must be `active`, except when it happens to be the currently-
 *      linked base (we always keep the current selection visible so an
 *      admin who just unarchived something or is editing a legacy row
 *      doesn't silently lose the link on save).
 *
 * If the current value points to a service that is not in `allServices`
 * at all (e.g. hard-deleted or a stale GUID), we render it as a
 * fallback "(missing service: <short id>)" entry so the admin can see
 * something's off and either keep or clear the link explicitly. If
 * `allServices` is undefined (older call sites that haven't wired it
 * yet) we fall back to the legacy free-text GUID input — storage is
 * still a GUID either way.
 */
function BaseServiceLinkField({
  currentValue,
  existingServiceId,
  allServices,
  onChange,
}: {
  currentValue: string | null
  existingServiceId: string | null
  allServices: readonly QuoteService[] | undefined
  onChange: (next: string | null) => void
}) {
  const eligible = useMemo(() => {
    if (!allServices) return []
    const list = allServices.filter((s) => {
      if (s.id === existingServiceId) return false
      if (s.inputType === 'extra_units') return false
      if (s.extraUnit?.linkToBaseServiceId) return false
      if (!s.active && s.id !== currentValue) return false
      return true
    })
    list.sort((a, b) => a.name.localeCompare(b.name))
    return list
  }, [allServices, existingServiceId, currentValue])

  if (!allServices) {
    return (
      <TextField
        id="svc-extra-link-base"
        label="Link To Base Service (optional)"
        value={currentValue ?? ''}
        onChange={(v) => onChange(v === '' ? null : v)}
        placeholder="service id"
      />
    )
  }

  const inList = eligible.some((s) => s.id === currentValue)
  const missing = currentValue != null && !inList
    ? allServices.find((s) => s.id === currentValue) ?? null
    : null

  return (
    <div>
      <label
        htmlFor="svc-extra-link-base"
        className="block text-sm font-medium text-slate-700"
      >
        Link To Base Service (optional)
      </label>
      <select
        id="svc-extra-link-base"
        value={currentValue ?? ''}
        onChange={(e) => {
          const next = e.target.value
          onChange(next === '' ? null : next)
        }}
        className="mt-1 w-full rounded-md border border-slate-200 bg-white px-3 py-2 text-sm text-slate-800 focus:border-emerald-400 focus:outline-none focus:ring-1 focus:ring-emerald-400"
      >
        <option value="">— None —</option>
        {eligible.map((s) => (
          <option key={s.id} value={s.id}>
            {s.internalKey ? `${s.name} — ${s.internalKey}` : s.name}
          </option>
        ))}
        {missing ? (
          <option key={missing.id} value={missing.id}>
            {(missing.internalKey
              ? `${missing.name} — ${missing.internalKey}`
              : missing.name) + ' (inactive or non-base)'}
          </option>
        ) : null}
        {currentValue != null && !inList && !missing ? (
          <option key={currentValue} value={currentValue}>
            {`(missing service: ${currentValue.slice(0, 8)}…)`}
          </option>
        ) : null}
      </select>
      <p className="mt-1 text-xs text-slate-500">
        Choose the base service this extra-unit row rolls up into. Leave
        as &ldquo;None&rdquo; for a standalone extras row.
      </p>
    </div>
  )
}
