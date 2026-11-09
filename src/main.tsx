import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

import { ConfigErrorScreen } from '@/app/ConfigErrorScreen'
import { ErrorBoundary } from '@/app/ErrorBoundary'
import { Providers } from '@/app/providers'
import { AppRouter } from '@/app/router'
import { LocalDevelopmentBanner } from '@/components/layout/LocalDevelopmentBanner'
import { getMissingSupabaseEnvNames, isLocalDevelopment } from '@/lib/env'
import './index.css'

const container = document.getElementById('root')
if (!container) {
  throw new Error('Root element #root not found')
}

const missingEnv = getMissingSupabaseEnvNames()

if (isLocalDevelopment()) {
  document.documentElement.dataset.appEnvironment = 'local'
}

createRoot(container).render(
  <StrictMode>
    <LocalDevelopmentBanner />
    {missingEnv.length > 0 ? (
      <ConfigErrorScreen missing={missingEnv} />
    ) : (
      <ErrorBoundary>
        <Providers>
          <AppRouter />
        </Providers>
      </ErrorBoundary>
    )}
  </StrictMode>,
)
