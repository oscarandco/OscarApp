import { useQuery } from '@tanstack/react-query'

import { fetchSavedQuoteDetail } from '@/features/quote/data/savedQuoteDetailApi'
import type { SavedQuoteDetail } from '@/features/quote/types/savedQuoteDetail'

export const savedQuoteDetailQueryKey = (quoteId: string) =>
  ['saved-quote-detail', quoteId] as const

/**
 * Load a single saved quote for the detail page. Enabled only when a
 * quoteId is available (guards the first render inside a route where
 * params are not yet parsed).
 */
export function useSavedQuoteDetail(quoteId: string | undefined) {
  return useQuery<SavedQuoteDetail, Error>({
    queryKey: savedQuoteDetailQueryKey(quoteId ?? ''),
    queryFn: () => fetchSavedQuoteDetail(quoteId as string),
    enabled: Boolean(quoteId),
  })
}
