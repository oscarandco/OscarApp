/**
 * Lightweight app logging — console-only by default.
 * Set `VITE_ENABLE_APP_LOGGING=true` for slightly more verbose client logs (still no external SDK).
 * Replace `logAppError` later with Sentry.captureException or similar if needed.
 */

function loggingVerbose(): boolean {
  return import.meta.env.VITE_ENABLE_APP_LOGGING === 'true'
}

/** Log unexpected errors (e.g. error boundary). Safe for production: no secrets, no PII by default. */
export function logAppError(
  error: unknown,
  context?: { componentStack?: string | null; source?: string },
): void {
  const prefix = context?.source ? `[app:${context.source}]` : '[app]'
  if (import.meta.env.DEV || loggingVerbose()) {
    console.error(prefix, error, context?.componentStack ?? '')
    return
  }
  // Production: one line so issues are visible in browser devtools without noisy logs
  if (error instanceof Error) {
    console.error(prefix, error.message)
  } else {
    console.error(prefix, error)
  }
}
