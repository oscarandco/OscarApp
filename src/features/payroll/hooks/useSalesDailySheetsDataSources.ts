import { useQuery } from '@tanstack/react-query'

import { rpcGetSalesDailySheetsDataSources } from '@/lib/supabaseRpc'

const QUERY_KEY = ['sales-daily-sheets-data-sources'] as const

/**
 * My Sales: source filename + row count + first/last sale date for
 * each active SalesDailySheets import batch (one per location).
 */
export function useSalesDailySheetsDataSources() {
  return useQuery({
    queryKey: QUERY_KEY,
    queryFn: rpcGetSalesDailySheetsDataSources,
  })
}
