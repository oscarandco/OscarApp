import { isLocalDevelopment } from '@/lib/env'

export function LocalDevelopmentBanner() {
  if (!isLocalDevelopment()) return null

  return (
    <aside
      className="sticky top-0 z-[60] flex h-8 items-center justify-center bg-amber-200 px-3 text-center text-xs font-semibold text-amber-950 print:hidden"
      role="status"
      data-testid="local-development-banner"
    >
      Local development · Docker database
    </aside>
  )
}
