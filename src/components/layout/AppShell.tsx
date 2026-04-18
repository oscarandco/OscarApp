import { useState } from 'react'
import { Outlet } from 'react-router-dom'

import { SideNav } from '@/components/layout/SideNav'
import { TopNav } from '@/components/layout/TopNav'

/**
 * Responsive app shell.
 *
 * Desktop (≥ lg): pinned header + left sidebar + a single scrollable
 * main column. The outer container claims the full dynamic viewport
 * height (`lg:h-dvh`) and hides its own overflow so only `<main>`
 * scrolls. `min-h-0` on the flex row lets `<main>` actually engage
 * `overflow-y-auto`.
 *
 * Mobile (< lg): the fixed-height chrome is **removed**. The shell
 * becomes a normal-document-flow column, the TopNav sits at the top of
 * the document (not sticky), and the body itself scrolls. This prevents
 * the app header from eating vertical real-estate as the stylist scrolls
 * through a long Guest Quote on phone. The mobile `SideNav` drawer is
 * overlaid with its own `fixed inset-0`, so it is unaffected by the
 * change in parent positioning.
 */
export function AppShell() {
  const [mobileNavOpen, setMobileNavOpen] = useState(false)

  return (
    <div className="flex min-h-dvh flex-col bg-slate-50 lg:h-dvh lg:min-h-0 lg:overflow-hidden">
      <TopNav onOpenMobileNav={() => setMobileNavOpen(true)} />
      <div className="flex flex-1 flex-col lg:min-h-0 lg:flex-row">
        <SideNav
          mobileOpen={mobileNavOpen}
          onMobileClose={() => setMobileNavOpen(false)}
        />
        <main
          className="min-w-0 flex-1 px-3 py-4 sm:px-4 sm:py-6 lg:overflow-y-auto lg:overflow-x-hidden lg:px-8"
          data-testid="app-shell-main"
        >
          <div className="w-full max-w-[85rem]">
            <Outlet />
          </div>
        </main>
      </div>
    </div>
  )
}
