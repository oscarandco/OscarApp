/**
 * Recognise the shared database readiness guard without treating missing costs as zero.
 */
export function isCommissionCostReadinessError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : String(error ?? '')
  return /commission awaiting product costs/i.test(message)
}

/** Normalize unknown errors from TanStack Query / RPC calls for ErrorState. */
export function queryErrorDetail(error: unknown): {
  err: Error | null
  message: string | undefined
} {
  if (error instanceof Error) {
    return { err: error, message: undefined }
  }
  return { err: null, message: String(error) }
}
