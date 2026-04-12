type EmptyStateProps = {
  title: string
  description?: string
  /** Optional hook for e2e / smoke tests */
  testId?: string
}

export function EmptyState({ title, description, testId }: EmptyStateProps) {
  return (
    <div
      className="rounded-lg border border-dashed border-slate-200 bg-white px-6 py-12 text-center"
      data-testid={testId}
    >
      <p className="text-sm font-medium text-slate-800">{title}</p>
      {description ? (
        <p className="mt-1 text-sm text-slate-600">{description}</p>
      ) : null}
    </div>
  )
}
