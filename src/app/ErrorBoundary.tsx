import { Component, type ErrorInfo, type ReactNode } from 'react'

import { logAppError } from '@/lib/logger'

type ErrorBoundaryProps = {
  children: ReactNode
}

type ErrorBoundaryState = {
  hasError: boolean
}

/**
 * Catches render errors in the tree below. Does not catch event handlers or async code.
 */
export class ErrorBoundary extends Component<
  ErrorBoundaryProps,
  ErrorBoundaryState
> {
  state: ErrorBoundaryState = { hasError: false }

  static getDerivedStateFromError(): ErrorBoundaryState {
    return { hasError: true }
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    logAppError(error, {
      componentStack: info.componentStack ?? undefined,
      source: 'ErrorBoundary',
    })
  }

  render(): ReactNode {
    if (this.state.hasError) {
      return (
        <div
          className="flex min-h-dvh flex-col items-center justify-center bg-slate-50 px-4 py-12 text-center"
          data-testid="app-error-boundary"
        >
          <div className="max-w-md rounded-xl border border-slate-200 bg-white px-6 py-8 shadow-sm">
            <h1 className="text-lg font-semibold text-slate-900">
              Something went wrong
            </h1>
            <p className="mt-2 text-sm text-slate-600">
              The app hit an unexpected error. You can try reloading the page.
              If this keeps happening, contact your administrator.
            </p>
            <button
              type="button"
              className="mt-6 rounded-md bg-violet-600 px-4 py-2 text-sm font-medium text-white shadow hover:bg-violet-700"
              onClick={() => window.location.reload()}
            >
              Reload page
            </button>
          </div>
        </div>
      )
    }

    return this.props.children
  }
}
