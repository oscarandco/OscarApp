type LoadingStateProps = {
  message?: string
  fullPage?: boolean
  testId?: string
}

export function LoadingState({
  message = 'Loading…',
  fullPage = false,
  testId,
}: LoadingStateProps) {
  const inner = (
    <div
      className="flex flex-col items-center justify-center gap-3 py-12"
      data-testid={testId}
    >
      <div
        className="h-9 w-9 animate-spin rounded-full border-2 border-slate-200 border-t-violet-600"
        aria-hidden
      />
      <p className="text-sm text-slate-600">{message}</p>
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
