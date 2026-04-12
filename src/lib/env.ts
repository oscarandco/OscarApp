/**
 * Supabase browser configuration (Vite `import.meta.env`).
 * `main.tsx` checks `getMissingSupabaseEnvNames()` before mounting the app; `src/lib/supabase.ts`
 * only calls `createClient` when URL and anon key are both non-empty.
 */

export function getMissingSupabaseEnvNames(): string[] {
  const missing: string[] = []
  if (!import.meta.env.VITE_SUPABASE_URL?.trim()) {
    missing.push('VITE_SUPABASE_URL')
  }
  if (!import.meta.env.VITE_SUPABASE_ANON_KEY?.trim()) {
    missing.push('VITE_SUPABASE_ANON_KEY')
  }
  return missing
}

/** Non-null URL and anon key when configured; otherwise `null`. */
export function getSupabaseEnvOrNull(): { url: string; anonKey: string } | null {
  const url = import.meta.env.VITE_SUPABASE_URL?.trim()
  const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY?.trim()
  if (!url || !anonKey) return null
  return { url, anonKey }
}

/** Storage bucket for Sales Daily Sheets CSV uploads (import pipeline). */
export function getSalesDailySheetsBucket(): string {
  return (
    import.meta.env.VITE_SALES_DAILY_SHEETS_BUCKET?.trim() ||
    'sales-daily-sheets'
  )
}

/**
 * Object key prefix inside the bucket (e.g. `incoming/`).
 * Leading/trailing slashes normalized.
 */
export function getSalesDailySheetsPathPrefix(): string {
  const raw = import.meta.env.VITE_SALES_DAILY_SHEETS_PATH_PREFIX?.trim()
  if (!raw) return 'incoming/'
  const withSlash = raw.includes('/') ? raw : `${raw}/`
  return withSlash.startsWith('/') ? withSlash.slice(1) : withSlash
}
