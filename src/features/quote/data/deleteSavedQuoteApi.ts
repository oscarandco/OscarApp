/**
 * Data layer for hard-deleting a saved quote.
 *
 * Calls the SECURITY DEFINER RPC `public.delete_saved_quote(p_id)` which
 * enforces the same stylist-vs-elevated access rule as the read RPCs.
 * Child rows (lines, line options, section totals) cascade via FKs.
 */
import type { PostgrestError } from '@supabase/supabase-js'

import { requireSupabaseClient } from '@/lib/supabase'

function toError(op: string, err: PostgrestError | Error): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

/** Delete a saved quote by id. Resolves on success; throws on failure. */
export async function deleteSavedQuote(quoteId: string): Promise<void> {
  const { error } = await requireSupabaseClient().rpc('delete_saved_quote', {
    p_saved_quote_id: quoteId,
  })
  if (error) throw toError('delete_saved_quote', error)
}
