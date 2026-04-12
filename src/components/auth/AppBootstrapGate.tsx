import type { ReactNode } from 'react'

import { ErrorState } from '@/components/feedback/ErrorState'
import { LoadingState } from '@/components/feedback/LoadingState'
import { useAccessProfile } from '@/features/access/accessContext'
import { AccessInactivePage } from '@/pages/AccessInactivePage'
import { NoAccessPage } from '@/pages/NoAccessPage'

type AppBootstrapGateProps = {
  children: ReactNode
}

/** Waits for access profile RPC, then shows no-access / inactive screens or children. */
export function AppBootstrapGate({ children }: AppBootstrapGateProps) {
  const { accessState, isLoading, error, refetch } = useAccessProfile()

  if (isLoading) {
    return <LoadingState fullPage message="Loading your access…" />
  }

  if (accessState === 'error') {
    return (
      <ErrorState
        fullPage
        title="Could not load your access profile"
        error={error}
        onRetry={() => refetch()}
      />
    )
  }

  if (accessState === 'no_access') {
    return <NoAccessPage />
  }

  if (accessState === 'inactive') {
    return <AccessInactivePage />
  }

  return <>{children}</>
}
