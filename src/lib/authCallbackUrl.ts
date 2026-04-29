/**
 * Supabase puts invite / recovery / magic-link tokens in the URL as either:
 * - Hash fragment: `#access_token=...&type=signup|recovery|...`
 * - PKCE query: `?code=...`
 *
 * If those land on `/` or `/login`, React can navigate away before the user
 * reaches `/reset-password`, dropping the hash or skipping password setup.
 */
export function hasSupabaseAuthCallbackInUrl(): boolean {
  if (typeof window === 'undefined') return false
  const { hash, search } = window.location
  if (hash.includes('access_token')) return true
  if (hash.includes('type=signup')) return true
  if (hash.includes('type=recovery')) return true
  const q = new URLSearchParams(search)
  if (q.has('code')) return true
  return false
}

/** Path + same query + hash so `detectSessionInUrl` can run on `/reset-password`. */
export function buildResetPasswordPath(): string {
  const { search, hash } = window.location
  return `/reset-password${search}${hash}`
}
