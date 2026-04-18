/**
 * Supabase data layer for the admin Quote Configuration UI.
 *
 * Reads hit the quote_* tables directly (RLS elevates admins); writes that
 * touch more than one table route through SECURITY DEFINER RPCs
 * (save_quote_service, delete_quote_section) so deferred constraint triggers
 * and unique display_order constraints stay happy.
 */
import { requireSupabaseClient } from '@/lib/supabase'
import type {
  ExtraUnitConfig,
  NumericMultiplierConfig,
  QuoteConfiguration,
  QuoteRole,
  QuoteRolePriceMap,
  QuoteSection,
  QuoteService,
  QuoteServiceOption,
  QuoteSettings,
  SpecialExtraProductConfig,
} from '@/features/admin/types/quoteConfiguration'
import { QUOTE_ROLES } from '@/features/admin/types/quoteConfiguration'

import type { PostgrestError } from '@supabase/supabase-js'

type Row = Record<string, unknown>

function toError(op: string, err: PostgrestError | Error): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

function asRows<T>(data: T | T[] | null): T[] {
  if (data == null) return []
  return Array.isArray(data) ? data : [data]
}

function asNumber(v: unknown): number {
  if (v == null) return 0
  if (typeof v === 'number') return v
  const n = Number(v)
  return Number.isFinite(n) ? n : 0
}

function asNumberOrNull(v: unknown): number | null {
  if (v == null) return null
  if (typeof v === 'number') return Number.isFinite(v) ? v : null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

function asString(v: unknown): string {
  return typeof v === 'string' ? v : v == null ? '' : String(v)
}

function asStringOrNull(v: unknown): string | null {
  if (v == null) return null
  return typeof v === 'string' ? v : String(v)
}

function asBool(v: unknown, fallback: boolean): boolean {
  return typeof v === 'boolean' ? v : fallback
}

function asStringArray(v: unknown): string[] {
  if (!Array.isArray(v)) return []
  return v.filter((x): x is string => typeof x === 'string')
}

function mapSettings(row: Row): QuoteSettings {
  return {
    greenFeeAmount: asNumber(row.green_fee_amount),
    notesEnabled: asBool(row.notes_enabled, true),
    guestNameRequired: asBool(row.guest_name_required, false),
    quotePageTitle: asString(row.quote_page_title) || 'Guest Quote',
    active: asBool(row.active, true),
    updatedAt: asString(row.updated_at),
  }
}

function mapSection(row: Row): QuoteSection {
  return {
    id: asString(row.id),
    name: asString(row.name),
    summaryLabel: asString(row.summary_label),
    displayOrder: asNumber(row.display_order),
    active: asBool(row.active, true),
    sectionHelpText: asStringOrNull(row.section_help_text),
    usedInSavedQuotes: false,
    createdAt: asString(row.created_at),
    updatedAt: asString(row.updated_at),
  }
}

function mapOption(row: Row): QuoteServiceOption {
  return {
    id: asString(row.id),
    label: asString(row.label),
    valueKey: asString(row.value_key),
    displayOrder: asNumber(row.display_order),
    active: asBool(row.active, true),
    price: asNumberOrNull(row.price),
  }
}

function mapNumericConfig(v: unknown): NumericMultiplierConfig | null {
  if (v == null || typeof v !== 'object') return null
  const o = v as Row
  return {
    unitLabel: asString(o.unitLabel) || 'unit',
    pricePerUnit: asNumber(o.pricePerUnit),
    min: asNumber(o.min),
    max: asNumber(o.max),
    step: asNumber(o.step) || 1,
    defaultValue: asNumber(o.defaultValue),
    roundTo: asNumberOrNull(o.roundTo),
    minCharge: asNumberOrNull(o.minCharge),
  }
}

function mapExtraUnitConfig(v: unknown): ExtraUnitConfig | null {
  if (v == null || typeof v !== 'object') return null
  const o = v as Row
  return {
    baseIncludedAmountLabel: asStringOrNull(o.baseIncludedAmountLabel),
    extraLabel: asString(o.extraLabel) || 'Extra',
    extraUnitDisplaySuffix: asStringOrNull(o.extraUnitDisplaySuffix),
    pricePerExtraUnit: asNumber(o.pricePerExtraUnit),
    maxExtras: asNumber(o.maxExtras),
    optionStyle: 'radio_1_to_n',
    linkToBaseServiceId: asStringOrNull(o.linkToBaseServiceId),
  }
}

function mapSpecialExtraConfig(v: unknown): SpecialExtraProductConfig | null {
  if (v == null || typeof v !== 'object') return null
  const o = v as Row
  // `numberOfRows` / `maxUnitsPerRow` are deprecated multi-row calculator
  // fields — read and preserved verbatim so the admin save path (which
  // writes the whole `extraSpecialConfig` JSONB back) round-trips them
  // unchanged. The admin drawer no longer exposes them.
  return {
    numberOfRows: asNumber(o.numberOfRows),
    maxUnitsPerRow: asNumber(o.maxUnitsPerRow),
    pricePerUnit: asNumber(o.pricePerUnit),
    gramsPerUnit: asNumber(o.gramsPerUnit),
    minutesPerUnit: asNumber(o.minutesPerUnit),
    blueSummaryLabelTemplate:
      asString(o.blueSummaryLabelTemplate) ||
      '{units} units / {grams} grams or {minutes} mins',
  }
}

function mapService(
  row: Row,
  optionsByService: Map<string, QuoteServiceOption[]>,
  rolePricesByService: Map<string, QuoteRolePriceMap>,
): QuoteService {
  const id = asString(row.id)

  // `link_to_base_service_id` is stored authoritatively on the
  // top-level `quote_services` column (that's what the save RPC writes
  // and what `get_active_quote_config` returns to the stylist page).
  // The drawer, however, models the link as a field on
  // `extraUnit.linkToBaseServiceId`, and the admin save path reads it
  // from there on submit. Prior to this fix, `mapService` only
  // hydrated the nested field from whatever happened to be inside the
  // `extra_unit_config` JSONB — which for seeded rows was nothing —
  // so opening a seeded extra-unit service in the drawer silently
  // showed "no link", and then the very next save stamped
  // `link_to_base_service_id = NULL` back over the top-level column,
  // breaking the Guest Quote rollup. Hydrate from the top-level
  // column here so the drawer round-trips correctly.
  const topLevelLinkToBase = asStringOrNull(row.link_to_base_service_id)
  const extraUnitBase = mapExtraUnitConfig(row.extra_unit_config)
  const extraUnit: QuoteService['extraUnit'] = extraUnitBase
    ? { ...extraUnitBase, linkToBaseServiceId: topLevelLinkToBase }
    : null

  return {
    id,
    sectionId: asString(row.section_id),
    name: asString(row.name),
    internalKey: asStringOrNull(row.internal_key),
    active: asBool(row.active, true),
    displayOrder: asNumber(row.display_order),
    helpText: asStringOrNull(row.help_text),
    summaryLabelOverride: asStringOrNull(row.summary_label_override),
    inputType: asString(row.input_type) as QuoteService['inputType'],
    pricingType: asString(row.pricing_type) as QuoteService['pricingType'],
    visibleRoles: asStringArray(row.visible_roles) as QuoteRole[],
    options: (optionsByService.get(id) ?? []).slice().sort(
      (a, b) => a.displayOrder - b.displayOrder,
    ),
    fixedPrice: asNumberOrNull(row.fixed_price),
    rolePrices: rolePricesByService.get(id) ?? {},
    numeric: mapNumericConfig(row.numeric_config),
    extraUnit,
    specialExtra: mapSpecialExtraConfig(row.special_extra_config),
    includeInQuoteSummary: asBool(row.include_in_quote_summary, true),
    summaryGroupOverride: asStringOrNull(row.summary_group_override),
    adminNotes: asStringOrNull(row.admin_notes),
    usedInSavedQuotes: false,
    createdAt: asString(row.created_at),
    updatedAt: asString(row.updated_at),
  }
}

/** Fetches every configuration table in parallel and returns the bundle. */
export async function fetchQuoteConfiguration(): Promise<QuoteConfiguration> {
  const supabase = requireSupabaseClient()
  const [settingsRes, sectionsRes, servicesRes, optionsRes, rolePricesRes] =
    await Promise.all([
      supabase.from('quote_settings').select('*').eq('id', 1).single(),
      supabase.from('quote_sections').select('*').order('display_order'),
      supabase.from('quote_services').select('*').order('display_order'),
      supabase.from('quote_service_options').select('*').order('display_order'),
      supabase.from('quote_service_role_prices').select('*'),
    ])

  if (settingsRes.error) throw toError('quote_settings', settingsRes.error)
  if (sectionsRes.error) throw toError('quote_sections', sectionsRes.error)
  if (servicesRes.error) throw toError('quote_services', servicesRes.error)
  if (optionsRes.error) throw toError('quote_service_options', optionsRes.error)
  if (rolePricesRes.error)
    throw toError('quote_service_role_prices', rolePricesRes.error)

  const optionsByService = new Map<string, QuoteServiceOption[]>()
  for (const raw of asRows(optionsRes.data as Row[])) {
    const serviceId = asString(raw.service_id)
    const list = optionsByService.get(serviceId) ?? []
    list.push(mapOption(raw))
    optionsByService.set(serviceId, list)
  }

  const rolePricesByService = new Map<string, QuoteRolePriceMap>()
  for (const raw of asRows(rolePricesRes.data as Row[])) {
    const serviceId = asString(raw.service_id)
    const map = rolePricesByService.get(serviceId) ?? {}
    const role = asString(raw.role) as QuoteRole
    if (QUOTE_ROLES.includes(role)) {
      map[role] = asNumberOrNull(raw.price)
    }
    rolePricesByService.set(serviceId, map)
  }

  return {
    settings: mapSettings(settingsRes.data as Row),
    sections: asRows(sectionsRes.data as Row[]).map(mapSection),
    services: asRows(servicesRes.data as Row[]).map((r) =>
      mapService(r, optionsByService, rolePricesByService),
    ),
  }
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

export async function updateQuoteSettings(
  input: Omit<QuoteSettings, 'updatedAt'>,
): Promise<void> {
  const { error } = await requireSupabaseClient()
    .from('quote_settings')
    .update({
      green_fee_amount: input.greenFeeAmount,
      notes_enabled: input.notesEnabled,
      guest_name_required: input.guestNameRequired,
      quote_page_title: input.quotePageTitle,
      active: input.active,
    })
    .eq('id', 1)
  if (error) throw toError('quote_settings update', error)
}

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

export type InsertSectionInput = {
  name: string
  summaryLabel: string
  displayOrder: number
  active: boolean
}

export async function insertQuoteSection(
  input: InsertSectionInput,
): Promise<QuoteSection> {
  const { data, error } = await requireSupabaseClient()
    .from('quote_sections')
    .insert({
      name: input.name.trim(),
      summary_label: input.summaryLabel.trim() || input.name.trim(),
      display_order: input.displayOrder,
      active: input.active,
    })
    .select('*')
    .single()
  if (error) throw toError('quote_sections insert', error)
  return mapSection(data as Row)
}

export type UpdateSectionInput = {
  id: string
  name?: string
  summaryLabel?: string
  displayOrder?: number
  active?: boolean
  sectionHelpText?: string | null
}

export async function updateQuoteSection(
  input: UpdateSectionInput,
): Promise<void> {
  const patch: Row = {}
  if (input.name != null) patch.name = input.name.trim()
  if (input.summaryLabel != null) patch.summary_label = input.summaryLabel.trim()
  if (input.displayOrder != null) patch.display_order = input.displayOrder
  if (input.active != null) patch.active = input.active
  if (input.sectionHelpText !== undefined) {
    patch.section_help_text =
      input.sectionHelpText == null ? null : input.sectionHelpText
  }
  if (Object.keys(patch).length === 0) return
  const { error } = await requireSupabaseClient()
    .from('quote_sections')
    .update(patch)
    .eq('id', input.id)
  if (error) throw toError('quote_sections update', error)
}

/**
 * Two-pass renumber to avoid tripping `UNIQUE (display_order) DEFERRABLE
 * INITIALLY IMMEDIATE`. First we bump every affected row to `final + 10000`
 * (always unique relative to real orders), then we flip them to their final
 * contiguous values. Rows whose target order already matches are skipped in
 * both passes so no-op reorders are free.
 */
export async function reorderQuoteSections(orderedIds: string[]): Promise<void> {
  const supabase = requireSupabaseClient()
  if (orderedIds.length === 0) return

  const pairs = orderedIds.map((id, idx) => ({ id, next: idx + 1 }))

  await Promise.all(
    pairs.map(({ id, next }) =>
      supabase
        .from('quote_sections')
        .update({ display_order: next + 10000 })
        .eq('id', id)
        .then(({ error }) => {
          if (error) throw toError('quote_sections reorder pass 1', error)
        }),
    ),
  )

  await Promise.all(
    pairs.map(({ id, next }) =>
      supabase
        .from('quote_sections')
        .update({ display_order: next })
        .eq('id', id)
        .then(({ error }) => {
          if (error) throw toError('quote_sections reorder pass 2', error)
        }),
    ),
  )
}

/** Hard-delete a section and all its services via SECURITY DEFINER RPC. */
export async function deleteQuoteSection(sectionId: string): Promise<void> {
  const { error } = await requireSupabaseClient().rpc('delete_quote_section', {
    p_section_id: sectionId,
  })
  if (error) throw toError('delete_quote_section', error)
}

// ---------------------------------------------------------------------------
// Services
// ---------------------------------------------------------------------------

/**
 * Upserts a service (and its options + role prices) via the save_quote_service
 * RPC. The server returns the service id. Client-generated draft option ids
 * (starting with `opt_draft_`) are stripped so the database generates fresh
 * UUIDs.
 */
export async function saveQuoteService(input: {
  id: string | null
  service: Partial<QuoteService> & { sectionId: string; name: string }
}): Promise<string> {
  const s = input.service
  const payload: Row = {
    id: input.id,
    section_id: s.sectionId,
    name: s.name,
    internal_key: s.internalKey ?? null,
    active: s.active ?? true,
    display_order: s.displayOrder ?? null,
    help_text: s.helpText ?? null,
    summary_label_override: s.summaryLabelOverride ?? null,
    input_type: s.inputType ?? 'checkbox',
    pricing_type: s.pricingType ?? 'fixed_price',
    visible_roles: s.visibleRoles ?? [],
    fixed_price: s.fixedPrice ?? null,
    numeric_config: s.numeric ?? null,
    extra_unit_config: s.extraUnit ?? null,
    special_extra_config: s.specialExtra ?? null,
    link_to_base_service_id:
      s.extraUnit?.linkToBaseServiceId ?? null,
    include_in_quote_summary: s.includeInQuoteSummary ?? true,
    summary_group_override: s.summaryGroupOverride ?? null,
    admin_notes: s.adminNotes ?? null,
    role_prices: s.rolePrices
      ? Object.entries(s.rolePrices)
          .filter(([, v]) => v != null && Number.isFinite(Number(v)))
          .map(([role, price]) => ({ role, price: Number(price) }))
      : [],
    options: (s.options ?? []).map((o) => ({
      id:
        typeof o.id === 'string' && o.id.startsWith('opt_draft_') ? null : o.id,
      label: o.label,
      value_key: o.valueKey,
      display_order: o.displayOrder,
      active: o.active,
      price: o.price ?? null,
    })),
  }

  const { data, error } = await requireSupabaseClient().rpc(
    'save_quote_service',
    { payload },
  )
  if (error) throw toError('save_quote_service', error)
  return asString(data)
}

/**
 * Reorder services within a section using the same two-pass technique as
 * sections (the composite unique is on `(section_id, display_order)`, so only
 * the one section is at risk).
 */
export async function reorderQuoteServicesInSection(
  sectionId: string,
  orderedIds: string[],
): Promise<void> {
  const supabase = requireSupabaseClient()
  if (orderedIds.length === 0) return

  const pairs = orderedIds.map((id, idx) => ({ id, next: idx + 1 }))

  await Promise.all(
    pairs.map(({ id, next }) =>
      supabase
        .from('quote_services')
        .update({ display_order: next + 10000 })
        .eq('id', id)
        .eq('section_id', sectionId)
        .then(({ error }) => {
          if (error) throw toError('quote_services reorder pass 1', error)
        }),
    ),
  )

  await Promise.all(
    pairs.map(({ id, next }) =>
      supabase
        .from('quote_services')
        .update({ display_order: next })
        .eq('id', id)
        .eq('section_id', sectionId)
        .then(({ error }) => {
          if (error) throw toError('quote_services reorder pass 2', error)
        }),
    ),
  )
}

export async function deleteQuoteService(serviceId: string): Promise<void> {
  const { error } = await requireSupabaseClient()
    .from('quote_services')
    .delete()
    .eq('id', serviceId)
  if (error) throw toError('quote_services delete', error)
}
