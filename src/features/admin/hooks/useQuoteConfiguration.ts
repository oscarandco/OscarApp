import { useQuery } from '@tanstack/react-query'

import type {
  QuoteConfiguration,
  QuoteSection,
  QuoteService,
} from '@/features/admin/types/quoteConfiguration'
import { fetchQuoteConfiguration } from '@/lib/quoteConfigurationApi'

/** Shared query key so mutations can invalidate from anywhere. */
export const quoteConfigurationQueryKey = ['quote-configuration'] as const

/**
 * Loads the complete admin Quote Configuration bundle (settings, sections,
 * services, options, role prices) in a single React Query. All admin pages and
 * mutations hang off this one key so a single invalidate refetches everything.
 */
export function useQuoteConfiguration() {
  return useQuery({
    queryKey: quoteConfigurationQueryKey,
    queryFn: fetchQuoteConfiguration,
  })
}

export function sectionsInOrder(config: QuoteConfiguration): QuoteSection[] {
  return [...config.sections].sort((a, b) => a.displayOrder - b.displayOrder)
}

export function servicesForSection(
  config: QuoteConfiguration,
  sectionId: string,
): QuoteService[] {
  return config.services
    .filter((s) => s.sectionId === sectionId)
    .sort((a, b) => a.displayOrder - b.displayOrder)
}

export function serviceCountForSection(
  config: QuoteConfiguration,
  sectionId: string,
): number {
  let n = 0
  for (const s of config.services) if (s.sectionId === sectionId) n++
  return n
}
