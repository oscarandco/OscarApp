import { useQuery } from '@tanstack/react-query'

import { fetchStylistQuoteConfig } from '@/features/quote/data/stylistQuoteConfigApi'

/** Shared query key so future mutations (save_guest_quote, etc.) can invalidate. */
export const stylistQuoteConfigQueryKey = ['stylist-quote-config'] as const

/**
 * Loads the active Guest Quote configuration via the
 * `public.get_active_quote_config()` RPC. Any authenticated user may call it.
 */
export function useStylistQuoteConfig() {
  return useQuery({
    queryKey: stylistQuoteConfigQueryKey,
    queryFn: fetchStylistQuoteConfig,
  })
}
