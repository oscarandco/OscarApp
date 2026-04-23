import { useQuery } from '@tanstack/react-query'

import { useAccessProfile } from '@/features/access/accessContext'
import {
  rpcGetInvoiceDetailLive,
  type KpiInvoiceDetailArgs,
  type KpiInvoiceDetailRow,
} from '@/features/kpi/data/kpiApi'

type UseKpiInvoiceDetailArgs = Partial<KpiInvoiceDetailArgs> & {
  /** Parent controls when the popup is open — we only fire on open. */
  enabled?: boolean
}

/**
 * Fetch every line on an invoice tuple (invoice, location_id,
 * sale_date) backing the KPI drilldown invoice-detail popup. Gated on
 * both `enabled` (parent-controlled popup open state) and a non-empty
 * `invoice` so we never fire an unusable RPC call.
 */
export function useKpiInvoiceDetail(
  args: UseKpiInvoiceDetailArgs,
): ReturnType<typeof useQuery<KpiInvoiceDetailRow[], Error>> {
  const { accessState } = useAccessProfile()
  const { invoice, locationId, saleDate, enabled = true } = args
  const hasInvoice =
    typeof invoice === 'string' && invoice.trim().length > 0

  return useQuery<KpiInvoiceDetailRow[], Error>({
    queryKey: [
      'kpi-invoice-detail-live',
      invoice ?? null,
      locationId ?? null,
      saleDate ?? null,
    ] as const,
    queryFn: () =>
      rpcGetInvoiceDetailLive({
        invoice: invoice as string,
        locationId: locationId ?? null,
        saleDate: saleDate ?? null,
      }),
    enabled: accessState === 'ready' && enabled && hasInvoice,
    staleTime: 60 * 1000,
  })
}
