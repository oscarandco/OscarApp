/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL?: string
  readonly VITE_SUPABASE_ANON_KEY?: string
  /** Set to `true` for slightly more verbose client error logging (still console-only). */
  readonly VITE_ENABLE_APP_LOGGING?: string
  /** Supabase Storage bucket for Sales Daily Sheets CSV (default: sales-daily-sheets). */
  readonly VITE_SALES_DAILY_SHEETS_BUCKET?: string
  /** Prefix for uploaded object keys (default: incoming/). */
  readonly VITE_SALES_DAILY_SHEETS_PATH_PREFIX?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
