import { AppBootstrapGate } from '@/components/auth/AppBootstrapGate'
import { AppShell } from '@/components/layout/AppShell'
import { AccessProvider } from '@/features/access/accessContext'

export function AuthenticatedLayout() {
  return (
    <AccessProvider>
      <AppBootstrapGate>
        <AppShell />
      </AppBootstrapGate>
    </AccessProvider>
  )
}
