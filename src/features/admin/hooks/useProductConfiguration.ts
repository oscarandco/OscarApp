import { useQuery } from '@tanstack/react-query'

import type { ProductMasterRow } from '@/features/admin/types/productConfiguration'
import { fetchProductMaster } from '@/lib/productMasterApi'

export type ProductConfigurationBundle = {
  products: ProductMasterRow[]
}

export function useProductConfiguration() {
  return useQuery({
    queryKey: ['product-configuration'],
    queryFn: async (): Promise<ProductConfigurationBundle> => {
      const products = await fetchProductMaster()
      return { products }
    },
  })
}
