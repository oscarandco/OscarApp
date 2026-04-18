/**
 * Guest Quote service row.
 *
 * Two distinct rendering paths:
 *
 *   • Desktop (≥ lg): the classic compact worksheet row using the
 *     shared `guestQuoteRowGridClasses` grid — leading actions, green
 *     price, service label, inline control, all in one aligned line.
 *     Unchanged from before; this path preserves every worksheet
 *     alignment fix previously shipped.
 *
 *   • Mobile (< lg): a dedicated stacked layout that drops the rigid
 *     desktop grid entirely. The top line carries leading actions +
 *     price + service name, wrapping cleanly inside the container; the
 *     controls sit on a second line below, with wrapping option
 *     groups so nothing runs off-screen in portrait or landscape.
 *
 * Both paths share the same control components, event handlers and
 * pricing inputs — only presentation differs.
 */
import type { ReactNode } from 'react'

import {
  QUOTE_ROLES,
  sortRolesCanonical,
  type QuoteRole,
} from '@/features/admin/types/quoteConfiguration'
import { guestQuoteRowGridClasses } from '@/features/quote/components/guestQuoteRowGrid'
import type { GuestQuoteLineDraft } from '@/features/quote/state/guestQuoteDraft'
import type { StylistQuoteService } from '@/features/quote/types/stylistQuoteConfig'
import { priceForLine } from '@/features/quote/lib/quoteCalculations'
import { formatNzd } from '@/lib/formatters'

type Props = {
  service: StylistQuoteService
  line: GuestQuoteLineDraft
  onChange: (patch: Partial<GuestQuoteLineDraft>) => void
  onClear: () => void
  displayedTotal: number | null
  onAdminEdit?: () => void
  adminEditBusy?: boolean
}

function shortRoleLabel(role: QuoteRole): string {
  switch (role) {
    case 'EMERGING':
      return 'Em.'
    case 'SENIOR':
      return 'Snr.'
    case 'MASTER':
      return 'Mst.'
    case 'DIRECTOR':
      return 'Dir.'
  }
}

function isExtraUnitsVariant(service: StylistQuoteService): boolean {
  return service.inputType === 'extra_units'
}

/**
 * Formats the live blue helper text for a `special_extra_product`
 * standalone row (e.g. "5 units / 90 grams or 50 mins"). See the
 * original comment for details — behaviour unchanged.
 */
function formatSpecialExtraMeta(
  service: StylistQuoteService,
  pricing: ReturnType<typeof priceForLine>,
): string {
  const cfg = service.specialExtra
  if (!cfg) return ''
  const units = pricing.specialExtra?.units ?? 0
  const unitWord = units === 1 ? 'unit' : 'units'
  const head = `${units} ${unitWord}`
  const tail: string[] = []
  if (cfg.gramsPerUnit > 0) tail.push(`${units * cfg.gramsPerUnit} grams`)
  if (cfg.minutesPerUnit > 0) tail.push(`${units * cfg.minutesPerUnit} mins`)
  return tail.length > 0 ? `${head} / ${tail.join(' or ')}` : head
}

/**
 * Compute the `extra_units` sub-row meta text ("3 foils @ $18.00 ea").
 * Shared between desktop and mobile renderers so both paths display
 * identical copy. Returns empty string for non-extra_units services.
 */
function formatExtraUnitsMeta(
  service: StylistQuoteService,
  line: GuestQuoteLineDraft,
): string {
  if (service.inputType !== 'extra_units') return ''
  const cfg = service.extraUnit
  const n = line.extraUnitsSelected ?? 0
  const each = cfg?.pricePerExtraUnit ?? 0
  const rawUnit =
    cfg?.extraUnitDisplaySuffix?.trim() ||
    cfg?.extraLabel?.toLowerCase().trim() ||
    'extras'
  return `${n} ${rawUnit} @ ${formatNzd(each)} ea`
}

export function GuestQuoteServiceField(props: Props) {
  // Render both variants inline and switch with responsive visibility —
  // simplest possible approach that keeps each layout purpose-built
  // for its viewport.
  return (
    <>
      <div className="hidden lg:block">
        <DesktopRow {...props} />
      </div>
      <div className="block lg:hidden">
        <MobileRow {...props} />
      </div>
    </>
  )
}

/* --------------------------------------------------------------------- */
/*  Desktop renderer (≥ lg) — unchanged grid-based worksheet row         */
/* --------------------------------------------------------------------- */

function DesktopRow({
  service,
  line,
  onChange,
  onClear,
  onAdminEdit,
  adminEditBusy,
  displayedTotal,
}: Props) {
  const pricing = priceForLine(service, line)
  const adminEditMode = typeof onAdminEdit === 'function'
  const gridClasses = guestQuoteRowGridClasses(adminEditMode)
  const leadingActions = (
    <LeadingRowActions
      serviceName={service.name}
      onClear={onClear}
      onAdminEdit={onAdminEdit}
      adminEditBusy={adminEditBusy ?? false}
    />
  )

  if (service.inputType === 'special_extra_product') {
    const metaText = formatSpecialExtraMeta(service, pricing)
    const name = service.name?.trim() ?? ''
    const title = name && metaText ? `${name} — ${metaText}` : name || metaText
    return (
      <div
        className={gridClasses}
        data-testid={`guest-quote-row-${service.id}`}
      >
        {leadingActions}
        <LinePriceLabel displayedTotal={displayedTotal} />
        <div className="min-w-0 break-words sm:truncate" title={title}>
          {name ? <span className="text-slate-800">{name}</span> : null}
          {name && metaText ? <span className="text-slate-800">: </span> : null}
          {metaText ? <span className="text-sky-600">{metaText}</span> : null}
        </div>
        <div className="flex min-w-0 items-center justify-start">
          <FieldControl service={service} line={line} onChange={onChange} />
        </div>
      </div>
    )
  }

  if (isExtraUnitsVariant(service)) {
    return (
      <div
        className={gridClasses}
        data-testid={`guest-quote-row-${service.id}`}
      >
        {leadingActions}
        <div className="col-span-2 min-w-0">
          <ExtraRowLabel service={service} line={line} centered />
        </div>
        <div className="flex min-w-0 items-center justify-start">
          <FieldControl service={service} line={line} onChange={onChange} />
        </div>
      </div>
    )
  }

  return (
    <div
      className={gridClasses}
      data-testid={`guest-quote-row-${service.id}`}
    >
      {leadingActions}
      <LinePriceLabel displayedTotal={displayedTotal} />
      <div
        className="min-w-0 break-words text-slate-800 sm:truncate"
        title={service.name}
      >
        {service.name}
      </div>
      <div className="flex min-w-0 items-center justify-start">
        <FieldControl service={service} line={line} onChange={onChange} />
      </div>
    </div>
  )
}

/* --------------------------------------------------------------------- */
/*  Mobile renderer (< lg) — stacked, wrap-friendly card-style row       */
/* --------------------------------------------------------------------- */

function MobileRow({
  service,
  line,
  onChange,
  onClear,
  onAdminEdit,
  adminEditBusy,
  displayedTotal,
}: Props) {
  const pricing = priceForLine(service, line)
  const name = service.name?.trim() ?? ''

  const leadingActions = (
    <LeadingRowActions
      serviceName={service.name}
      onClear={onClear}
      onAdminEdit={onAdminEdit}
      adminEditBusy={adminEditBusy ?? false}
    />
  )

  // Top line: [x/E buttons] [price or em-dash] [service label]
  // Price renders a fixed-width slot so labels line up across rows
  // regardless of whether the price is present, rolled-up, or absent.
  // For `extra_units` rows the price is always rolled into the parent,
  // so the price slot naturally shows a muted em-dash — no special
  // cased empty slot is needed.
  let topLabel: ReactNode = (
    <span className="min-w-0 flex-1 break-words text-[12.5px] text-slate-800">
      {name}
    </span>
  )
  const priceSlot = <MobilePriceLabel displayedTotal={displayedTotal} />

  if (service.inputType === 'extra_units') {
    const meta = formatExtraUnitsMeta(service, line)
    topLabel = (
      <span
        className="min-w-0 flex-1 break-words text-[12.5px]"
        title={name ? `${name} — ${meta}` : meta}
      >
        {name ? <span className="text-slate-800">{name}: </span> : null}
        <span className="text-sky-600">{meta}</span>
      </span>
    )
  } else if (service.inputType === 'special_extra_product') {
    const meta = formatSpecialExtraMeta(service, pricing)
    topLabel = (
      <span
        className="min-w-0 flex-1 break-words text-[12.5px]"
        title={name && meta ? `${name} — ${meta}` : name || meta}
      >
        {name ? <span className="text-slate-800">{name}</span> : null}
        {name && meta ? <span className="text-slate-800">: </span> : null}
        {meta ? <span className="text-sky-600">{meta}</span> : null}
      </span>
    )
  }

  return (
    <div
      className="border-b border-slate-200/60 py-1.5 last:border-b-0"
      data-testid={`guest-quote-row-${service.id}`}
    >
      <div className="flex items-center gap-2">
        {leadingActions}
        {priceSlot}
        {topLabel}
      </div>
      <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 pl-7">
        <FieldControl
          service={service}
          line={line}
          onChange={onChange}
          compact
        />
      </div>
    </div>
  )
}

/**
 * Mobile variant of the price label.
 *
 * Same semantics as `LinePriceLabel` but uses a narrow fixed-minimum
 * slot so the label column lines up across rows without requiring the
 * desktop grid template. No `NZD`/`$` localisation surprises on mobile
 * — the formatter is locked to `en-NZ` in `formatNzd`.
 */
function MobilePriceLabel({
  displayedTotal,
}: {
  displayedTotal: number | null
}) {
  if (displayedTotal == null) {
    return (
      <span
        className="w-[4.5rem] shrink-0 text-[12px] text-slate-300"
        aria-label="Included in linked service total"
        title="Included in linked service total"
      >
        —
      </span>
    )
  }
  return (
    <span className="w-[4.5rem] shrink-0 text-right text-[12.5px] font-semibold tabular-nums text-emerald-600">
      {formatNzd(displayedTotal)}
    </span>
  )
}

/* --------------------------------------------------------------------- */
/*  Shared helpers                                                        */
/* --------------------------------------------------------------------- */

function LeadingRowActions({
  serviceName,
  onClear,
  onAdminEdit,
  adminEditBusy,
}: {
  serviceName: string
  onClear: () => void
  onAdminEdit: (() => void) | undefined
  adminEditBusy: boolean
}) {
  return (
    <div className="flex items-center gap-1">
      {onAdminEdit ? (
        <button
          type="button"
          onClick={(e) => {
            e.stopPropagation()
            onAdminEdit()
          }}
          disabled={adminEditBusy}
          aria-busy={adminEditBusy}
          aria-label={`Edit configuration for ${serviceName}`}
          title="Edit service (admin)"
          data-testid="guest-quote-admin-edit"
          className="flex h-5 w-5 items-center justify-center rounded-full border border-rose-300 bg-rose-50 text-[11px] font-semibold text-rose-700 hover:border-rose-400 hover:bg-rose-100 disabled:cursor-wait disabled:opacity-60"
        >
          E
        </button>
      ) : null}
      <button
        type="button"
        onClick={(e) => {
          e.stopPropagation()
          onClear()
        }}
        aria-label="Clear this line"
        title="Clear line"
        className="flex h-5 w-5 items-center justify-center rounded-full border border-slate-300 text-[11px] font-medium text-slate-500 hover:border-slate-400 hover:bg-slate-50 hover:text-slate-700"
      >
        x
      </button>
    </div>
  )
}

function LinePriceLabel({
  displayedTotal,
}: {
  displayedTotal: number | null
}) {
  if (displayedTotal == null) {
    return (
      <span
        className="truncate text-slate-300"
        aria-label="Included in linked service total"
        title="Included in linked service total"
      >
        —
      </span>
    )
  }
  return (
    <span className="truncate font-semibold text-emerald-600">
      {formatNzd(displayedTotal)}
    </span>
  )
}

function ExtraRowLabel({
  service,
  line,
  centered,
}: {
  service: StylistQuoteService
  line: GuestQuoteLineDraft
  centered?: boolean
}) {
  const meta = formatExtraUnitsMeta(service, line)
  const name = service.name?.trim() ?? ''
  const alignClass = centered ? 'text-center' : ''
  return (
    <div
      className={`min-w-0 break-words sm:truncate ${alignClass}`.trim()}
      title={name ? `${name} — ${meta}` : meta}
    >
      {name ? (
        <span className="text-slate-800">{name}: </span>
      ) : null}
      <span className="text-sky-600">{meta}</span>
    </div>
  )
}

/* --------------------------------------------------------------------- */
/*  Inline controls                                                       */
/* --------------------------------------------------------------------- */

type ControlProps = {
  service: StylistQuoteService
  line: GuestQuoteLineDraft
  onChange: (patch: Partial<GuestQuoteLineDraft>) => void
  /**
   * When true, controls render with wrap-friendly spacing — smaller
   * gaps between radios/labels and no `whitespace-nowrap` — so option
   * groups and role selectors stay inside the available mobile width.
   */
  compact?: boolean
}

function FieldControl({
  service,
  line,
  onChange,
  compact,
}: Omit<Props, 'onClear' | 'onAdminEdit' | 'adminEditBusy' | 'displayedTotal'> & {
  compact?: boolean
}) {
  const c = compact ?? false
  switch (service.inputType) {
    case 'checkbox':
      return <CheckboxControl line={line} onChange={onChange} />
    case 'role_radio':
      return (
        <RoleRadioControl
          service={service}
          line={line}
          onChange={onChange}
          compact={c}
        />
      )
    case 'option_radio':
      return (
        <OptionRadioControl
          service={service}
          line={line}
          onChange={onChange}
          compact={c}
        />
      )
    case 'dropdown':
      return (
        <DropdownControl
          service={service}
          line={line}
          onChange={onChange}
          compact={c}
        />
      )
    case 'numeric_input':
      return <NumericControl service={service} line={line} onChange={onChange} />
    case 'extra_units':
      return (
        <ExtraUnitsControl
          service={service}
          line={line}
          onChange={onChange}
          compact={c}
        />
      )
    case 'special_extra_product':
      return <SpecialExtraControl service={service} line={line} onChange={onChange} />
    default:
      return (
        <InlineNote>Unsupported: {service.inputType}</InlineNote>
      )
  }
}

function InlineNote({ children }: { children: ReactNode }) {
  return (
    <span className="rounded border border-dashed border-amber-300 bg-amber-50 px-2 py-0.5 text-[11px] text-amber-800">
      {children}
    </span>
  )
}

function CheckboxControl({
  line,
  onChange,
}: {
  line: GuestQuoteLineDraft
  onChange: (patch: Partial<GuestQuoteLineDraft>) => void
}) {
  return (
    <input
      type="checkbox"
      aria-label="Include this service"
      className="h-4 w-4 rounded border-slate-300 text-emerald-600 focus:ring-emerald-500"
      checked={line.selected}
      onChange={(e) => onChange({ selected: e.target.checked })}
    />
  )
}

function RoleRadioControl({ service, line, onChange, compact }: ControlProps) {
  const canonicalRoles = sortRolesCanonical([...QUOTE_ROLES])
  const supported = new Set<QuoteRole>(
    service.visibleRoles.length > 0 ? service.visibleRoles : [...QUOTE_ROLES],
  )
  const active = line.selected ? line.selectedRole : null
  const containerClasses = compact
    ? 'flex flex-wrap items-center gap-x-3 gap-y-1'
    : 'flex items-center gap-3'
  const labelSizeClass = compact ? 'text-[11.5px]' : 'text-[12px]'
  return (
    <div className={containerClasses}>
      {canonicalRoles.map((role) => {
        if (!supported.has(role)) {
          return (
            <span
              key={role}
              aria-hidden="true"
              className={`pointer-events-none invisible flex select-none items-center gap-1 ${labelSizeClass} text-slate-700`}
            >
              <input
                type="radio"
                tabIndex={-1}
                className="h-3.5 w-3.5 border-slate-300 text-emerald-600 focus:ring-emerald-500"
                readOnly
                checked={false}
              />
              <span>{shortRoleLabel(role)}</span>
            </span>
          )
        }
        const checked = active === role
        return (
          <label
            key={role}
            className={`flex cursor-pointer items-center gap-1 ${labelSizeClass} text-slate-700`}
          >
            <input
              type="radio"
              name={`role-${service.id}`}
              className="h-3.5 w-3.5 border-slate-300 text-emerald-600 focus:ring-emerald-500"
              checked={checked}
              onChange={() =>
                onChange({ selected: true, selectedRole: role })
              }
            />
            <span>{shortRoleLabel(role)}</span>
          </label>
        )
      })}
    </div>
  )
}

function displayOptionLabel(label: string): string {
  return label.replace(/\s+(minutes?|mins?)\s*$/i, '').trim() || label
}

function OptionRadioControl({ service, line, onChange, compact }: ControlProps) {
  const activeId = line.selected ? line.selectedOptionIds[0] ?? null : null
  // Compact mode drops `whitespace-nowrap` and switches to wrap so
  // long option sets can break onto a second line on phone widths
  // instead of overflowing the container.
  const containerClasses = compact
    ? 'flex min-w-0 flex-wrap items-center gap-x-3 gap-y-1'
    : 'flex min-w-0 items-center gap-3 whitespace-nowrap'
  const labelSizeClass = compact ? 'text-[11.5px]' : 'text-[12px]'
  return (
    <div className={containerClasses}>
      {service.options.map((opt) => {
        const checked = activeId === opt.id
        return (
          <label
            key={opt.id}
            className={`flex cursor-pointer items-center gap-1 ${labelSizeClass} text-slate-700`}
          >
            <input
              type="radio"
              name={`opt-${service.id}`}
              className="h-3.5 w-3.5 border-slate-300 text-emerald-600 focus:ring-emerald-500"
              checked={checked}
              onChange={() =>
                onChange({ selected: true, selectedOptionIds: [opt.id] })
              }
            />
            <span>{displayOptionLabel(opt.label)}</span>
          </label>
        )
      })}
    </div>
  )
}

function DropdownControl({ service, line, onChange, compact }: ControlProps) {
  const activeId = line.selected ? line.selectedOptionIds[0] ?? '' : ''
  // Compact mode caps the select at the available width so long option
  // labels don't force the select wider than the container.
  const widthClass = compact ? 'w-full max-w-xs' : 'w-40'
  return (
    <select
      className={`${widthClass} rounded border border-slate-200 bg-white px-2 py-0.5 text-[12px] focus:border-emerald-400 focus:outline-none focus:ring-1 focus:ring-emerald-400`}
      value={activeId}
      onChange={(e) => {
        const id = e.target.value
        if (!id) onChange({ selected: false, selectedOptionIds: [] })
        else onChange({ selected: true, selectedOptionIds: [id] })
      }}
    >
      <option value=""></option>
      {service.options.map((opt) => (
        <option key={opt.id} value={opt.id}>
          {opt.label}
        </option>
      ))}
    </select>
  )
}

function NumericControl({ service, line, onChange }: ControlProps) {
  const cfg = service.numeric
  if (!cfg) return <InlineNote>Missing numeric config</InlineNote>
  const value = line.numericQuantity ?? ''
  return (
    <input
      type="number"
      inputMode="decimal"
      min={cfg.min}
      max={cfg.max}
      step={cfg.step || 1}
      value={value}
      placeholder=""
      aria-label={cfg.unitLabel || 'Quantity'}
      className="w-24 rounded border border-slate-200 bg-white px-2 py-0.5 text-right text-[12px] focus:border-emerald-400 focus:outline-none focus:ring-1 focus:ring-emerald-400"
      onChange={(e) => {
        const raw = e.target.value
        if (raw === '') {
          onChange({ selected: false, numericQuantity: null })
          return
        }
        const n = Number(raw)
        if (!Number.isFinite(n)) return
        onChange({ selected: n > 0, numericQuantity: n })
      }}
    />
  )
}

function ExtraUnitsControl({ service, line, onChange, compact }: ControlProps) {
  const cfg = service.extraUnit
  if (!cfg) return <InlineNote>Missing extra-unit config</InlineNote>
  const selected = line.extraUnitsSelected ?? 0
  const choices: number[] = []
  for (let i = 1; i <= cfg.maxExtras; i += 1) choices.push(i)
  const containerClasses = compact
    ? 'flex flex-wrap items-center gap-x-3 gap-y-1'
    : 'flex items-center gap-3'
  const labelSizeClass = compact ? 'text-[11.5px]' : 'text-[12px]'
  return (
    <div className={containerClasses}>
      {choices.map((n) => {
        const checked = line.selected && selected === n
        return (
          <label
            key={n}
            className={`flex cursor-pointer items-center gap-1 ${labelSizeClass} text-slate-700`}
          >
            <input
              type="radio"
              name={`extra-${service.id}`}
              className="h-3.5 w-3.5 border-slate-300 text-emerald-600 focus:ring-emerald-500"
              checked={checked}
              onChange={() =>
                onChange({ selected: true, extraUnitsSelected: n })
              }
            />
            <span>{n}</span>
          </label>
        )
      })}
    </div>
  )
}

function SpecialExtraControl({ service, line, onChange }: ControlProps) {
  const cfg = service.specialExtra
  if (!cfg) return <InlineNote>Missing special-extra config</InlineNote>
  const gramsPerUnit = cfg.gramsPerUnit > 0 ? cfg.gramsPerUnit : 1
  const qty =
    line.specialExtraGrams == null
      ? ''
      : Math.max(0, Math.ceil(line.specialExtraGrams / gramsPerUnit))
  return (
    <input
      type="number"
      inputMode="numeric"
      min={0}
      step={1}
      value={qty}
      placeholder="qty"
      aria-label="Quantity"
      className="w-20 rounded border border-slate-200 bg-white px-2 py-0.5 text-right text-[12px] focus:border-emerald-400 focus:outline-none focus:ring-1 focus:ring-emerald-400"
      onChange={(e) => {
        const raw = e.target.value
        if (raw === '') {
          onChange({ selected: false, specialExtraGrams: null })
          return
        }
        const n = Number(raw)
        if (!Number.isFinite(n) || n < 0) return
        onChange({
          selected: n > 0,
          specialExtraGrams: n * gramsPerUnit,
        })
      }}
    />
  )
}
