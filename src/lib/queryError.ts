/**
 * Normalize unknown errors from TanStack Query / RPC calls for {@link ErrorState}.
 */
export function queryErrorDetail(error: unknown): {
  err: Error | null
  message: string | undefined
} {
  if (error instanceof Error) {
    return { err: error, message: undefined }
  }
  return { err: null, message: String(error) }
}
