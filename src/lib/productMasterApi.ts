/**
 * Product master CRUD (elevated users only; RLS on `product_master`).
 */
import type { ProductMasterRow } from '@/features/admin/types/productConfiguration'
import { requireSupabaseClient } from '@/lib/supabase'

import type { PostgrestError } from '@supabase/supabase-js'

function toError(op: string, err: PostgrestError): Error {
  const msg = err.message || 'Unknown Supabase error'
  const e = new Error(`${op}: ${msg}`)
  e.cause = err
  return e
}

function asRows<T>(data: T | T[] | null): T[] {
  if (data == null) return []
  return Array.isArray(data) ? data : [data]
}

export async function fetchProductMaster(): Promise<ProductMasterRow[]> {
  const { data, error } = await requireSupabaseClient()
    .from('product_master')
    .select('*')
    .order('product_description')
  if (error) throw toError('product_master', error)
  return asRows(data as ProductMasterRow[])
}

export type ProductMasterInsertPayload = {
  product_description: string
  system_type?: string | null
  product_type?: string | null
  is_active?: boolean
}

export async function insertProductMaster(
  args: ProductMasterInsertPayload,
): Promise<ProductMasterRow> {
  const supabase = requireSupabaseClient()
  const { data, error } = await supabase
    .from('product_master')
    .insert({
      product_description: args.product_description.trim(),
      system_type: emptyToNull(args.system_type ?? null),
      product_type: emptyToNull(args.product_type ?? null),
      is_active: args.is_active ?? true,
    })
    .select('*')
    .single()
  if (error) throw toError('product_master insert', error)
  return data as ProductMasterRow
}

/**
 * Soft-delete (deactivate) a product. Product rows are kept for classification
 * history and reporting; we never hard-delete from the UI by default.
 */
export async function deactivateProductMaster(id: string): Promise<void> {
  const { error } = await requireSupabaseClient()
    .from('product_master')
    .update({ is_active: false })
    .eq('id', id)
  if (error) throw toError('product_master deactivate', error)
}

export type ProductMasterUpdatePayload = {
  id: string
  product_description: string
  system_type: string | null
  product_type: string | null
  is_active: boolean
}

export async function updateProductMaster(
  payload: ProductMasterUpdatePayload,
): Promise<void> {
  const { error } = await requireSupabaseClient()
    .from('product_master')
    .update({
      product_description: payload.product_description.trim(),
      system_type: emptyToNull(payload.system_type),
      product_type: emptyToNull(payload.product_type),
      is_active: payload.is_active,
    })
    .eq('id', payload.id)
  if (error) throw toError('product_master update', error)
}

function emptyToNull(s: string | null): string | null {
  if (s == null) return null
  const t = s.trim()
  return t === '' ? null : t
}
