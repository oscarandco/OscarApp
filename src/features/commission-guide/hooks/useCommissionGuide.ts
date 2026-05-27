import { useQuery } from '@tanstack/react-query'

import type { CommissionGuideEnvelope } from '@/features/commission-guide/types/commissionGuide'
import { fetchCommissionGuide } from '@/lib/commissionGuideApi'

/**
 * Load the commission guide for a staff member as at `asOfDate`.
 * Pass `staffMemberId = null` to load the caller's own guide (resolved
 * server-side from auth.uid()).
 */
export function useCommissionGuide(
  staffMemberId: string | null,
  asOfDate: string | null,
) {
  return useQuery<CommissionGuideEnvelope>({
    queryKey: ['commission-guide', staffMemberId ?? '__self__', asOfDate ?? '__today__'],
    queryFn: () => fetchCommissionGuide({ staffMemberId, asOfDate }),
    staleTime: 60_000,
  })
}
