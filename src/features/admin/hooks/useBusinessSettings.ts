import { useQuery } from '@tanstack/react-query'

import { rpcGetBusinessSettings } from '@/lib/contractorInvoicesApi'

export const BUSINESS_SETTINGS_QUERY_KEY = ['business-settings'] as const

export function useBusinessSettings() {
  return useQuery({
    queryKey: BUSINESS_SETTINGS_QUERY_KEY,
    queryFn: rpcGetBusinessSettings,
  })
}
