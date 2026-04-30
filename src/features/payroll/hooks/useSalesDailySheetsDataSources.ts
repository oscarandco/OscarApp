import { useQuery } from '@tanstack/react-query'

import { rpcGetSalesDailySheetsDataSources } from '@/lib/supabaseRpc'

const QUERY_KEY = ['sales-daily-sheets-data-sources'] as const

/**
 * My Sales / Sales Summary: `get_sales_daily_sheets_data_sources_by_location`
 * — per-location row count and sale_date range for current SalesDailySheets-
 * backed reporting rows (not grouped by import batch).
 */
export function useSalesDailySheetsDataSources() {
  return useQuery({
    queryKey: QUERY_KEY,
    queryFn: rpcGetSalesDailySheetsDataSources,
  })
}
