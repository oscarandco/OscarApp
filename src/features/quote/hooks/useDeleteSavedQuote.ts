import { useMutation, useQueryClient } from '@tanstack/react-query'

import { deleteSavedQuote } from '@/features/quote/data/deleteSavedQuoteApi'
import { savedQuoteDetailQueryKey } from '@/features/quote/hooks/useSavedQuoteDetail'

/**
 * Delete a saved quote, then tidy up the react-query cache:
 *   - invalidate every `saved-quotes-search` page so the list refetches
 *     with the row removed
 *   - drop the per-id detail cache entry so any still-mounted detail
 *     page cannot render stale data
 */
export function useDeleteSavedQuote() {
  const queryClient = useQueryClient()
  return useMutation<void, Error, string>({
    mutationFn: (quoteId) => deleteSavedQuote(quoteId),
    onSuccess: (_data, quoteId) => {
      void queryClient.invalidateQueries({ queryKey: ['saved-quotes-search'] })
      queryClient.removeQueries({
        queryKey: savedQuoteDetailQueryKey(quoteId),
      })
    },
  })
}
