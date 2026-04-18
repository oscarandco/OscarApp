/**
 * Compact Guest Quote service row.
 *
 * Row grammar (left → right):
 *   [x]   [price / live meta]   [service label]   [inline control]
 *
 * - `[x]`: clears this line back to an empty/unselected state.
 * - `[price]`: green live-calculated line total for normal services; blue
 *   live meta ("N units @ $X ea", "N units / Ng or N mins") for
 *   extra_unit / special_extra_product services.
 * - Controls render inline and stay compact; no heavy card wrappers.
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
  /**
   * The amount shown in the row's green price cell, pre-computed by the
   * page from `buildDisplayedRowTotals`. Differs from
   * `priceForLine(service, line).lineTotal` in two cases:
   *   - on a base service row it includes the raw totals of any linked
   *     child extra rows, so the visible green amount reflects the
   *     combined charge the stylist will quote;
   *   - on a linked child row it is `null`, and the row hides its
   *     standalone price (the amount is rolled up into the parent
   *     instead).
   * The draft state and save payload continue to use per-line totals,
   * so this rollup is purely display-level.
   */
  displayedTotal: number | null
  /**
   * Optional admin-only edit shortcut. When provided, a small red "E"
   * button is rendered next to the clear button and this callback is
   * invoked when clicked. Rendering is the caller's responsibility —
   * pass `undefined` for non-elevated users so the control is fully
   * absent from the DOM.
   */
  onAdminEdit?: () => void
  /**
   * Disables the admin edit button while the parent is loading or
   * saving the admin-side service config. Ignored when
   * `onAdminEdit` is not provided.
   */
  adminEditBusy?: boolean
}

/** Short role labels used inline in role_radio rows. */
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

/**
 * `extra_units` rows render as a sub-row variant: a wider merged
 * meta/label area and a centered compact control group, distinct from
 * the [price][label][controls] grammar of normal service rows. They
 * reuse the *same* grid template as normal rows (via `col-span-2` on
 * the merged cell), so the controls column starts at the same
 * horizontal position on every row across the whole worksheet.
 *
 * `special_extra_product` rows are **not** part of this variant — they
 * render as a normal priced row with a green visible total, a combined
 * "Name: blue meta" label, and a left-aligned numeric qty input. See
 * the dedicated branch in `GuestQuoteServiceField`.
 */
function isExtraUnitsVariant(service: StylistQuoteService): boolean {
  return service.inputType === 'extra_units'
}

/**
 * Formats the live blue helper text for a `special_extra_product`
 * standalone row. The entered quantity (see `SpecialExtraControl`) is
 * treated as a unit count, so:
 *
 *   units   = qty
 *   grams   = qty * gramsPerUnit   (only when gramsPerUnit > 0)
 *   minutes = qty * minutesPerUnit (only when minutesPerUnit > 0)
 *
 * Produces strings like:
 *   "5 units / 90 grams or 50 mins"      (both scales configured)
 *   "1 unit / 18 grams"                  (only grams configured)
 *   "3 units / 30 mins"                  (only minutes configured)
 *   "1 unit"                             (neither scale configured)
 *
 * Singular/plural for `unit` / `units` is preserved. This is purely
 * display — no persisted config fields, no line draft fields, and no
 * save payload mapping are affected.
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

export function GuestQuoteServiceField({
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
    // Standalone priced row. Uses the normal row grid so the green
    // `LinePriceLabel` is visible (same column as other priced rows),
    // and the numeric qty input sits in the same left-aligned control
    // column as checkboxes / numeric inputs / other standalone rows —
    // no merged col-span / center-justify treatment here.
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
        <div
          className="min-w-0 break-words text-[12px] sm:truncate sm:text-[13px]"
          title={title}
        >
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
    // `extra_units` sub-row: centered merged label/meta cell and a
    // left-aligned 1..N selector group. Unchanged.
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
        className="min-w-0 break-words text-[12px] text-slate-800 sm:truncate sm:text-[13px]"
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

/**
 * Renders the leading column of a service row: the "x" clear button, and
 * — for elevated users only — a small red "E" admin edit button. The
 * edit button is kept visually distinct from the clear button (red tint
 * vs slate outline, bold "E" vs lowercase "x") so the two actions are
 * not confused. Both buttons stop click propagation so they never fire
 * adjacent row-level interactions.
 */
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

/**
 * Live-updating price cell for normal service rows.
 * Extra-unit / special-extra rows use `ExtraRowLabel` instead, which
 * renders a wider blue meta label spanning the price + name columns.
 *
 * `displayedTotal` comes pre-computed from `buildDisplayedRowTotals`:
 *   - number   → render the green money amount (parent rows already
 *                include linked child totals, so this "just works")
 *   - null     → this row's price rolls up into its parent. Render a
 *                muted em-dash as a neutral placeholder so the column
 *                stays visually consistent across the worksheet.
 */
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

/**
 * Merged label for `extra_units` sub-rows. The service name is shown
 * plain (e.g. "Additional"), followed by the blue live-updating meta
 * so the row reads as a sub-row beneath its parent service:
 *
 *   Additional: 0 extra (0g)
 *   Individual extras: 2 foils @ $18.00 ea
 *
 * (`special_extra_product` has its own standalone priced row renderer
 * in `GuestQuoteServiceField` — see `formatSpecialExtraMeta`.)
 */
function ExtraRowLabel({
  service,
  line,
  centered,
}: {
  service: StylistQuoteService
  line: GuestQuoteLineDraft
  /**
   * When true, the meta/name text is rendered center-aligned inside its
   * column. Used for `extra_units` rows where the label block sits in a
   * wide merged cell and reads more naturally when centered under the
   * parent. Defaults to left-aligned (the original behaviour) for all
   * other variants.
   */
  centered?: boolean
}) {
  // `ExtraRowLabel` is now only used for `extra_units` sub-rows.
  // `special_extra_product` has its own standalone priced row renderer
  // in `GuestQuoteServiceField` — see `formatSpecialExtraMeta`.
  let meta = ''
  if (service.inputType === 'extra_units') {
    const cfg = service.extraUnit
    const n = line.extraUnitsSelected ?? 0
    const each = cfg?.pricePerExtraUnit ?? 0
    // Reference format: "{n} {unit} @ ${price} ea". Prefer the more
    // descriptive `extraUnitDisplaySuffix` (e.g. "units", "10g") over
    // the generic `extraLabel`; fall back to "extras" when neither is
    // set. Always separated by a space — prevents the old
    // "0 extra foilunits" / "0 extra10g" concatenation bug.
    const rawUnit =
      cfg?.extraUnitDisplaySuffix?.trim() ||
      cfg?.extraLabel?.toLowerCase().trim() ||
      'extras'
    meta = `${n} ${rawUnit} @ ${formatNzd(each)} ea`
  }

  const name = service.name?.trim() ?? ''
  const alignClass = centered ? 'text-center' : ''
  return (
    <div
      className={`min-w-0 break-words text-[12px] sm:truncate sm:text-[13px] ${alignClass}`.trim()}
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

function FieldControl({
  service,
  line,
  onChange,
}: Omit<Props, 'onClear' | 'onAdminEdit' | 'adminEditBusy' | 'displayedTotal'>) {
  switch (service.inputType) {
    case 'checkbox':
      return <CheckboxControl line={line} onChange={onChange} />
    case 'role_radio':
      return <RoleRadioControl service={service} line={line} onChange={onChange} />
    case 'option_radio':
      return <OptionRadioControl service={service} line={line} onChange={onChange} />
    case 'dropdown':
      return <DropdownControl service={service} line={line} onChange={onChange} />
    case 'numeric_input':
      return <NumericControl service={service} line={line} onChange={onChange} />
    case 'extra_units':
      return <ExtraUnitsControl service={service} line={line} onChange={onChange} />
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

type ControlProps = {
  service: StylistQuoteService
  line: GuestQuoteLineDraft
  onChange: (patch: Partial<GuestQuoteLineDraft>) => void
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

function RoleRadioControl({ service, line, onChange }: ControlProps) {
  // Always render the four canonical role slots in a fixed order so the
  // Em./Snr./Mst./Dir. columns line up across every role_radio row on
  // the worksheet, even when a service restricts which roles are
  // allowed. Unsupported roles render an inert, visually-hidden
  // placeholder of the same shape as a real radio+label — this keeps
  // the geometry identical without affecting pricing or selection.
  const canonicalRoles = sortRolesCanonical([...QUOTE_ROLES])
  const supported = new Set<QuoteRole>(
    service.visibleRoles.length > 0 ? service.visibleRoles : [...QUOTE_ROLES],
  )
  const active = line.selected ? line.selectedRole : null
  return (
    <div className="flex items-center gap-3">
      {canonicalRoles.map((role) => {
        if (!supported.has(role)) {
          return (
            <span
              key={role}
              aria-hidden="true"
              className="pointer-events-none invisible flex select-none items-center gap-1 text-[11px] text-slate-700 sm:text-[12px]"
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
            className="flex cursor-pointer items-center gap-1 text-[11px] text-slate-700 sm:text-[12px]"
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

/**
 * Strip a redundant trailing time unit from option labels whose parent
 * service name already implies minutes (e.g. "Additional mins reqd" →
 * options "15 min" / "30 min" render as "15" / "30"). Presentation-only;
 * option value_key, price, and saved payloads are unaffected.
 */
function displayOptionLabel(label: string): string {
  return label.replace(/\s+(minutes?|mins?)\s*$/i, '').trim() || label
}

function OptionRadioControl({ service, line, onChange }: ControlProps) {
  const activeId = line.selected ? line.selectedOptionIds[0] ?? null : null
  return (
    <div className="flex min-w-0 items-center gap-3 whitespace-nowrap">
      {service.options.map((opt) => {
        const checked = activeId === opt.id
        return (
          <label
            key={opt.id}
            className="flex cursor-pointer items-center gap-1 text-[11px] text-slate-700 sm:text-[12px]"
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

function DropdownControl({ service, line, onChange }: ControlProps) {
  const activeId = line.selected ? line.selectedOptionIds[0] ?? '' : ''
  return (
    <select
      className="w-40 rounded border border-slate-200 bg-white px-2 py-0.5 text-[12px] focus:border-emerald-400 focus:outline-none focus:ring-1 focus:ring-emerald-400"
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

function ExtraUnitsControl({ service, line, onChange }: ControlProps) {
  const cfg = service.extraUnit
  if (!cfg) return <InlineNote>Missing extra-unit config</InlineNote>
  // Linked extras are always enabled — picking an option auto-activates
  // the base service via the page-level patch handler. This keeps the
  // UX from forcing users to tick the base checkbox first.
  const selected = line.extraUnitsSelected ?? 0
  const choices: number[] = []
  for (let i = 1; i <= cfg.maxExtras; i += 1) choices.push(i)
  return (
    <div className="flex items-center gap-3">
      {choices.map((n) => {
        const checked = line.selected && selected === n
        return (
          <label
            key={n}
            className="flex cursor-pointer items-center gap-1 text-[11px] text-slate-700 sm:text-[12px]"
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
  // The input now represents a unit quantity (qty). We still persist to
  // `specialExtraGrams` so `priceForLine` and the save payload mapping
  // remain byte-identical: the stored grams value is exactly
  // `qty * gramsPerUnit`, which `priceForLine` divides back out to
  // recover the same units count. When `gramsPerUnit` is 0 (unusual —
  // time-only config), we fall back to multiplier 1 so storing qty as
  // grams still yields the same units via `Math.ceil(grams / 1)`.
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
