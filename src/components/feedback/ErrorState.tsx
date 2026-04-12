type ErrorStateProps = {
  title?: string
  message?: string
  error?: Error | null
  onRetry?: () => void
  fullPage?: boolean
  testId?: string
}

export function ErrorState({
  title = 'Something went wrong',
  message,
  error,
  onRetry,
  fullPage = false,
  testId,
}: ErrorStateProps) {
  const detail = message ?? error?.message ?? 'Please try again.'

  const inner = (
    <div
      className="mx-auto max-w-md rounded-lg border border-red-200 bg-red-50 px-4 py-6 text-center"
      role="alert"
      data-testid={testId}
    >
      <h2 className="text-base font-semibold text-red-900">{title}</h2>
      <p className="mt-2 text-sm text-red-800">{detail}</p>
      {onRetry ? (
        <button
          type="button"
          onClick={onRetry}
          className="mt-4 rounded-md bg-red-700 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-800"
        >
          Retry
        </button>
      ) : null}
    </div>
  )

  if (fullPage) {
    return (
      <div className="flex min-h-dvh items-center justify-center bg-slate-50 px-4">
        {inner}
      </div>
    )
  }

  return inner
}
