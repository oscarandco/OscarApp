import type { ReactNode } from 'react'

type TableScrollAreaProps = {
  children: ReactNode
  /** For e2e / smoke tests */
  testId?: string
}

/**
 * Horizontal scroll container for wide data tables + subtle hint on narrow viewports.
 */
export function TableScrollArea({ children, testId }: TableScrollAreaProps) {
  return (
    <div className="w-full space-y-1.5">
      <p
        className="pl-0.5 text-xs text-slate-500 sm:hidden"
        aria-hidden
      >
        Scroll horizontally for all columns →
      </p>
      <div
        className="w-full overflow-x-auto rounded-lg border border-slate-200 bg-white shadow-sm [-webkit-overflow-scrolling:touch]"
        data-testid={testId}
      >
        {children}
      </div>
    </div>
  )
}
