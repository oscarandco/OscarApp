import { createClient, type SupabaseClient } from '@supabase/supabase-js'

import { getSupabaseEnvOrNull } from '@/lib/env'

const env = getSupabaseEnvOrNull()

/**
 * Browser Supabase client (anon key). `null` when required env vars are missing — in that case
 * `main.tsx` renders the config error screen and the app shell does not mount.
 * All payroll data must go through RPC helpers in `supabaseRpc.ts`.
 */
export const supabase: SupabaseClient | null = env
  ? createClient(env.url, env.anonKey, {
      auth: {
        persistSession: true,
        autoRefreshToken: true,
        detectSessionInUrl: true,
      },
    })
  : null

/**
 * Returns the client when configured. Prefer this in code that only runs after the env gate
 * (e.g. inside `AuthProvider` or RPC calls). Throws if env was not configured — should not
 * happen when `getMissingSupabaseEnvNames()` is empty at startup.
 */
export function requireSupabaseClient(): SupabaseClient {
  if (!supabase) {
    throw new Error('Supabase client is not configured (missing VITE_SUPABASE_URL or VITE_SUPABASE_ANON_KEY)')
  }
  return supabase
}
