import { useQuery } from '@tanstack/react-query'

import { searchSavedQuotes } from '@/features/quote/data/savedQuotesApi'
import type {
  SavedQuoteSearchFilters,
  SavedQuoteSearchRow,
} from '@/features/quote/types/savedQuote'

export const savedQuotesSearchQueryKey = (filters: SavedQuoteSearchFilters) =>
  [
    'saved-quotes-search',
    {
      search: filters.search ?? null,
      stylist: filters.stylist ?? null,
      guestName: filters.guestName ?? null,
      dateFrom: filters.dateFrom ?? null,
      dateTo: filters.dateTo ?? null,
      limit: filters.limit ?? 100,
      offset: filters.offset ?? 0,
    },
  ] as const

/**
 * Load a page of previous saved quotes. Visibility (own vs all) is
 * decided server-side in `public.get_saved_quotes_search`.
 */
export function useSavedQuotesSearch(filters: SavedQuoteSearchFilters) {
  return useQuery<SavedQuoteSearchRow[], Error>({
    queryKey: savedQuotesSearchQueryKey(filters),
    queryFn: () => searchSavedQuotes(filters),
  })
}
