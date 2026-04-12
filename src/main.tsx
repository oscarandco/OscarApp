import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'

import { ConfigErrorScreen } from '@/app/ConfigErrorScreen'
import { ErrorBoundary } from '@/app/ErrorBoundary'
import { Providers } from '@/app/providers'
import { AppRouter } from '@/app/router'
import { getMissingSupabaseEnvNames } from '@/lib/env'
import './index.css'

const container = document.getElementById('root')
if (!container) {
  throw new Error('Root element #root not found')
}

const missingEnv = getMissingSupabaseEnvNames()

if (missingEnv.length > 0) {
  createRoot(container).render(
    <StrictMode>
      <ConfigErrorScreen missing={missingEnv} />
    </StrictMode>,
  )
} else {
  createRoot(container).render(
    <StrictMode>
      <ErrorBoundary>
        <Providers>
          <AppRouter />
        </Providers>
      </ErrorBoundary>
    </StrictMode>,
  )
}
