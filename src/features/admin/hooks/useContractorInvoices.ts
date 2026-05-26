import { useQuery } from '@tanstack/react-query'

import {
  rpcGetContractorInvoice,
  rpcGetContractorInvoiceBatch,
  rpcGetContractorInvoicePreview,
  rpcListContractorInvoicePayWeeks,
  rpcListContractorVoidedInvoicesForWeek,
} from '@/lib/contractorInvoicesApi'

export function useContractorInvoicePayWeeks() {
  return useQuery({
    queryKey: ['contractor-invoice-pay-weeks'] as const,
    queryFn: rpcListContractorInvoicePayWeeks,
  })
}

export function useContractorInvoiceBatch(args: {
  payWeekStart: string | undefined
  includeZeroContractors: boolean
}) {
  return useQuery({
    queryKey: [
      'contractor-invoice-batch',
      args.payWeekStart ?? null,
      args.includeZeroContractors,
    ] as const,
    queryFn: () =>
      rpcGetContractorInvoiceBatch({
        payWeekStart: args.payWeekStart!,
        includeZeroContractors: args.includeZeroContractors,
      }),
    enabled: Boolean(args.payWeekStart),
  })
}

export function useContractorInvoicePreview(args: {
  payWeekStart: string | undefined
  staffMemberId: string | undefined
}) {
  return useQuery({
    queryKey: [
      'contractor-invoice-preview',
      args.payWeekStart ?? null,
      args.staffMemberId ?? null,
    ] as const,
    queryFn: () =>
      rpcGetContractorInvoicePreview({
        payWeekStart: args.payWeekStart!,
        staffMemberId: args.staffMemberId!,
      }),
    enabled: Boolean(args.payWeekStart) && Boolean(args.staffMemberId),
  })
}

export function useContractorInvoice(invoiceId: string | undefined) {
  return useQuery({
    queryKey: ['contractor-invoice', invoiceId ?? null] as const,
    queryFn: () => rpcGetContractorInvoice(invoiceId!),
    enabled: Boolean(invoiceId),
  })
}

/**
 * Voided invoices for the selected pay week. Backs the "Show voided
 * invoices" toggle on the Contractor Invoices batch page. Disabled
 * unless both a pay week and the toggle are active so we don't waste
 * a round trip on the default view.
 */
export function useContractorVoidedInvoicesForWeek(args: {
  payWeekStart: string | undefined
  enabled: boolean
}) {
  return useQuery({
    queryKey: [
      'contractor-voided-invoices-week',
      args.payWeekStart ?? null,
    ] as const,
    queryFn: () => rpcListContractorVoidedInvoicesForWeek(args.payWeekStart!),
    enabled: args.enabled && Boolean(args.payWeekStart),
  })
}
