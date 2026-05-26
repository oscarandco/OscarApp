/**
 * Row shape for `public.business_settings` (Admin > Business Settings).
 * Singleton table — only one row exists ever (row_marker = 'singleton').
 */
export type BusinessSettingsRow = {
  id: string
  legal_business_name: string
  trading_name: string | null
  street_address: string
  suburb: string
  city_postcode: string
  email: string | null
  phone: string | null
  nzbn: string | null
  gst_number: string | null
  created_at: string
  updated_at: string
  updated_by: string | null
}

/** Required-for-invoice-creation fields per Contractor Invoices spec. */
export const BUSINESS_SETTINGS_REQUIRED_FIELDS: Array<keyof BusinessSettingsRow> = [
  'legal_business_name',
  'street_address',
  'suburb',
  'city_postcode',
]

export function businessSettingsMissingRequiredFields(
  row: BusinessSettingsRow | null | undefined,
): Array<keyof BusinessSettingsRow> {
  if (!row) return [...BUSINESS_SETTINGS_REQUIRED_FIELDS]
  const out: Array<keyof BusinessSettingsRow> = []
  for (const k of BUSINESS_SETTINGS_REQUIRED_FIELDS) {
    const v = row[k]
    if (v == null || String(v).trim() === '') out.push(k)
  }
  return out
}
