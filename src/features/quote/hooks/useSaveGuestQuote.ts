import { useMutation } from '@tanstack/react-query'

import {
  saveGuestQuote,
  type SaveGuestQuotePayload,
} from '@/features/quote/data/saveGuestQuoteApi'

/**
 * Submits a Guest Quote via `public.save_guest_quote(payload)` and
 * returns the new `saved_quotes.id`. Callers own the reset-on-success
 * behaviour — this hook is intentionally side-effect free beyond the
 * network round trip.
 */
export function useSaveGuestQuote() {
  return useMutation<string, Error, SaveGuestQuotePayload>({
    mutationFn: (payload) => saveGuestQuote(payload),
  })
}
