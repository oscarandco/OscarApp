/**
 * Client wrapper for `public.get_staff_commission_guide`.
 *
 * The RPC is read-only and SECURITY DEFINER (see migration
 * `20260828120500_commission_guide.sql`). Non-elevated callers can only
 * fetch their own guide; elevated callers may pass any staff_member_id.
 */
import type { CommissionGuideEnvelope } from '@/features/commission-guide/types/commissionGuide'
import { requireSupabaseClient } from '@/lib/supabase'

import type { PostgrestError } from '@supabase/supabase-js'

export type FetchCommissionGuideArgs = {
  /**
   * Staff member to load. `null`/`undefined` resolves to the caller's
   * own staff_member_id (only valid if caller has an active staff
   * mapping).
   */
  staffMemberId?: string | null
  /** YYYY-MM-DD. Defaults to today in the database. */
  asOfDate?: string | null
}

function toError(op: string, err: PostgrestError): Error {
  const parts = [err.message, err.details, err.hint].filter(Boolean)
  return new Error(`${op}: ${parts.join(' — ')}`)
}

export async function fetchCommissionGuide(
  args: FetchCommissionGuideArgs = {},
): Promise<CommissionGuideEnvelope> {
  const { data, error } = await requireSupabaseClient().rpc(
    'get_staff_commission_guide',
    {
      p_staff_member_id: args.staffMemberId ?? null,
      p_as_of_date: args.asOfDate ?? null,
    },
  )
  if (error) throw toError('get_staff_commission_guide', error)
  return data as CommissionGuideEnvelope
}
