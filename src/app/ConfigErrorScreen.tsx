type ConfigErrorScreenProps = {
  /** Env variable names that are missing or empty (no values shown). */
  missing: string[]
}

/**
 * Shown when required Vite env vars are not set — avoids obscure Supabase/runtime failures.
 */
export function ConfigErrorScreen({ missing }: ConfigErrorScreenProps) {
  return (
    <div
      className="flex min-h-dvh flex-col items-center justify-center bg-slate-50 px-4 py-12 text-center"
      data-testid="config-error-screen"
    >
      <div className="max-w-md rounded-xl border border-amber-200 bg-amber-50 px-6 py-8 shadow-sm">
        <h1 className="text-lg font-semibold text-amber-950">
          Configuration required
        </h1>
        <p className="mt-2 text-sm text-amber-900">
          This app needs Supabase settings in your environment before it can run.
          Add the following to a{' '}
          <code className="rounded bg-amber-100 px-1 font-mono text-xs">
            .env
          </code>{' '}
          file (or your host&apos;s env UI), then restart the dev server or
          redeploy:
        </p>
        <ul className="mt-4 list-inside list-disc text-left text-sm font-mono text-amber-950">
          {missing.map((name) => (
            <li key={name}>{name}</li>
          ))}
        </ul>
        <p className="mt-4 text-xs text-amber-800">
          Values are not shown here. See <code className="font-mono">.env.example</code>{' '}
          in the project root for the expected variable names.
        </p>
      </div>
    </div>
  )
}
