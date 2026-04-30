type StepVisual = 'pending' | 'current' | 'done' | 'failed'

function stepVisual(
  index: number,
  opts: {
    isRunning: boolean
    isFailed: boolean
    failureAt: number | null
    /** While running: steps [0, effective) done; effective is current (last step completes only when allComplete). */
    cursor: number
    allComplete: boolean
    numSteps: number
  },
): StepVisual {
  const { isRunning, isFailed, failureAt, cursor, allComplete, numSteps } = opts
  if (allComplete) return 'done'
  if (isFailed) {
    const at = failureAt ?? Math.max(0, numSteps - 2)
    if (index < at) return 'done'
    if (index === at) return 'failed'
    return 'pending'
  }
  if (!isRunning) return 'pending'
  const lastWorkIndex = numSteps - 2
  const effective = Math.min(Math.max(cursor, 0), lastWorkIndex)
  if (index < effective) return 'done'
  if (index === effective) return 'current'
  return 'pending'
}

function StepIcon({ visual, spinClass }: { visual: StepVisual; spinClass: string }) {
  if (visual === 'done') {
    return (
      <span className="mt-0.5 inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-emerald-600 text-xs font-bold text-white">
        ✓
      </span>
    )
  }
  if (visual === 'current') {
    return (
      <span
        className={`mt-0.5 inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full border-2 border-t-transparent animate-spin ${spinClass}`}
        aria-hidden
      />
    )
  }
  if (visual === 'failed') {
    return (
      <span className="mt-0.5 inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full bg-red-600 text-xs font-bold text-white">
        !
      </span>
    )
  }
  return (
    <span className="mt-0.5 inline-flex h-5 w-5 shrink-0 items-center justify-center rounded-full border border-current opacity-40" />
  )
}

export function AdminImportsRpcStepProgress(props: {
  variant: 'sky' | 'red'
  steps: readonly string[]
  isRunning: boolean
  isFailed: boolean
  failureAt: number | null
  /** Simulated progress while RPC runs. */
  cursor: number
  /** When true, every step shows completed. */
  allComplete: boolean
  /** Shown below the list (success one-liner or failure). */
  resultLine: string | null
}) {
  const { variant, steps, isRunning, isFailed, failureAt, cursor, allComplete, resultLine } = props
  const border =
    variant === 'sky' ? 'border-sky-200 bg-white/80' : 'border-red-200 bg-white/80'
  const textMain = variant === 'sky' ? 'text-sky-950' : 'text-red-950'
  const textMuted = variant === 'sky' ? 'text-sky-900/85' : 'text-red-900/85'
  const spinClass = variant === 'sky' ? 'border-sky-600' : 'border-red-700'

  return (
    <div
      className={`mt-4 rounded-lg border px-3 py-3 shadow-sm ${border}`}
      role="status"
      aria-live="polite"
    >
      <ol className="list-none space-y-2 pl-0">
        {steps.map((label, i) => {
          const visual = stepVisual(i, {
            isRunning,
            isFailed,
            failureAt,
            cursor,
            allComplete,
            numSteps: steps.length,
          })
          const rowCls =
            visual === 'current'
              ? 'font-medium'
              : visual === 'done'
                ? 'opacity-95'
                : visual === 'failed'
                  ? 'font-medium text-red-800'
                  : 'opacity-55'
          return (
            <li key={label} className={`flex gap-2 text-sm ${textMain} ${rowCls}`}>
              <StepIcon visual={visual} spinClass={spinClass} />
              <span className={variant === 'sky' ? 'text-sky-950' : 'text-red-950'}>{label}</span>
            </li>
          )
        })}
      </ol>
      {resultLine ? (
        <p
          className={`mt-3 border-t pt-3 text-sm leading-relaxed whitespace-pre-wrap ${
            isFailed ? 'border-red-200 text-red-900' : `border-current/10 ${textMuted}`
          }`}
        >
          {resultLine}
        </p>
      ) : null}
    </div>
  )
}
