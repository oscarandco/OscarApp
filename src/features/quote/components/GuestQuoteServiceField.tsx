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
import type { GuestQuoteLineDraft } from '@/features/quote/state/guestQuoteDraft'
import type { StylistQuoteService } from '@/features/quote/types/stylistQuoteConfig'
import { priceForLine } from '@/features/quote/lib/quoteCalculations'
import { formatNzd } from '@/lib/formatters'

type Props = {
  service: StylistQuoteService
  line: GuestQuoteLineDraft
  onChange: (patch: Partial<GuestQuoteLineDraft>) => void
  onClear: () => void
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
 * Extra-unit / special-extra rows render as a sub-row variant: a wider
 * merged meta/label area and a centered compact control group, distinct
 * from the [price][label][controls] grammar of normal service rows. They
 * reuse the *same* grid template as normal rows (via `col-span-2` on the
 * merged cell), so the controls column starts at the same horizontal
 * position on every row across the whole worksheet.
 */
function isExtraVariant(service: StylistQuoteService): boolean {
  return (
    service.inputType === 'extra_units' ||
    service.inputType === 'special_extra_product'
  )
}

/**
 * Shared grid template for every Guest Quote worksheet row. One template
 * keeps the controls column perfectly aligned across all sections, so
 * the control start-x is identical on every row on the page.
 *
 *   col 1 — clear button         (20px)
 *   col 2 — green price          (56px, fits "$1,000.00")
 *   col 3 — service label        (240px, fits longest live label)
 *   col 4 — control group        (remaining width)
 *
 * Gap tightened to 6px to remove the wide dead-space between price,
 * label, and controls that earlier iterations suffered from.
 */
const ROW_GRID_CLASSES =
  'grid grid-cols-[20px_56px_240px_minmax(0,1fr)] items-center gap-x-1.5 py-1 text-[13px]'

export function GuestQuoteServiceField({
  service,
  line,
  onChange,
  onClear,
}: Props) {
  const pricing = priceForLine(service, line)

  if (isExtraVariant(service)) {
    return (
      <div
        className={ROW_GRID_CLASSES}
        data-testid={`guest-quote-row-${service.id}`}
      >
        <ResetLineButton onClear={onClear} />
        <div className="col-span-2 min-w-0">
          <ExtraRowLabel service={service} line={line} pricing={pricing} />
        </div>
        {/* Controls land in the shared col-4 and left-align like normal
            rows, so extra/additional radios + grams inputs visually sit
            in the same control region instead of drifting right. */}
        <div className="flex min-w-0 items-center justify-start">
          <FieldControl service={service} line={line} onChange={onChange} />
        </div>
      </div>
    )
  }

  return (
    <div
      className={ROW_GRID_CLASSES}
      data-testid={`guest-quote-row-${service.id}`}
    >
      <ResetLineButton onClear={onClear} />
      <LinePriceLabel pricing={pricing} />
      <div className="min-w-0 truncate text-slate-800" title={service.name}>
        {service.name}
      </div>
      <div className="flex min-w-0 items-center justify-start">
        <FieldControl service={service} line={line} onChange={onChange} />
      </div>
    </div>
  )
}

function ResetLineButton({ onClear }: { onClear: () => void }) {
  return (
    <button
      type="button"
      onClick={onClear}
      aria-label="Clear this line"
      title="Clear line"
      className="flex h-5 w-5 items-center justify-center rounded-full border border-slate-300 text-[11px] font-medium text-slate-500 hover:border-slate-400 hover:bg-slate-50 hover:text-slate-700"
    >
      x
    </button>
  )
}

/**
 * Live-updating price cell for normal service rows.
 * Extra-unit / special-extra rows use `ExtraRowLabel` instead, which
 * renders a wider blue meta label spanning the price + name columns.
 */
function LinePriceLabel({
  pricing,
}: {
  pricing: ReturnType<typeof priceForLine>
}) {
  return (
    <span className="truncate font-semibold text-emerald-600">
      {formatNzd(pricing.lineTotal)}
    </span>
  )
}

/**
 * Merged label for extra-unit / special-extra rows. The service name is
 * shown plain (e.g. "Additional"), followed by the blue live-updating
 * meta so the row reads as a sub-row beneath its parent service:
 *
 *   Additional: 0 extra (0g)
 *   Olaplex: 2 units / 36 grams or 20 mins
 *   0 units @ $10 ea     (when the service has no name of its own)
 */
function ExtraRowLabel({
  service,
  line,
  pricing,
}: {
  service: StylistQuoteService
  line: GuestQuoteLineDraft
  pricing: ReturnType<typeof priceForLine>
}) {
  let meta = ''
  if (service.inputType === 'special_extra_product') {
    const cfg = service.specialExtra
    const grams = line.specialExtraGrams ?? 0
    const units = pricing.specialExtra?.units ?? 0
    const minutes =
      pricing.specialExtra?.minutes ??
      (cfg ? units * cfg.minutesPerUnit : 0)
    meta = `${units} units / ${grams} grams or ${minutes} mins`
  } else if (service.inputType === 'extra_units') {
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
  return (
    <div className="min-w-0 truncate" title={name ? `${name} — ${meta}` : meta}>
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
}: Omit<Props, 'onClear'>) {
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
  const roles: QuoteRole[] = sortRolesCanonical(
    service.visibleRoles.length > 0 ? service.visibleRoles : [...QUOTE_ROLES],
  )
  const active = line.selected ? line.selectedRole : null
  return (
    <div className="flex items-center gap-3">
      {roles.map((role) => {
        const checked = active === role
        return (
          <label
            key={role}
            className="flex cursor-pointer items-center gap-1 text-[12px] text-slate-700"
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
            className="flex cursor-pointer items-center gap-1 text-[12px] text-slate-700"
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
            className="flex cursor-pointer items-center gap-1 text-[12px] text-slate-700"
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
  const value = line.specialExtraGrams ?? ''
  return (
    <input
      type="number"
      inputMode="decimal"
      min={0}
      step={1}
      value={value}
      placeholder="grams"
      aria-label="Grams used"
      className="w-24 rounded border border-slate-200 bg-white px-2 py-0.5 text-right text-[12px] focus:border-emerald-400 focus:outline-none focus:ring-1 focus:ring-emerald-400"
      onChange={(e) => {
        const raw = e.target.value
        if (raw === '') {
          onChange({ selected: false, specialExtraGrams: null })
          return
        }
        const n = Number(raw)
        if (!Number.isFinite(n) || n < 0) return
        onChange({ selected: n > 0, specialExtraGrams: n })
      }}
    />
  )
}
