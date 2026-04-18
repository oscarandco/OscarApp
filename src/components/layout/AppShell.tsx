import { Outlet } from 'react-router-dom'

import { SideNav } from '@/components/layout/SideNav'
import { TopNav } from '@/components/layout/TopNav'

/**
 * Fixed app shell.
 *
 * The outer container claims the full dynamic viewport height
 * (`h-dvh`) and hides its own overflow, so the page itself never
 * scrolls. Inside it we lay out three regions:
 *
 *   1. `TopNav` — stays pinned at the top (first item in the column).
 *   2. `SideNav` — sits in the middle row and stretches the full
 *      remaining height. It can scroll internally via
 *      `overflow-y-auto` if the menu ever grows beyond the viewport
 *      (e.g. a long admin list), but never pushes the shell.
 *   3. `<main>` — the ONLY vertical scroll container in the shell.
 *      Long pages (Guest Quote, Previous Quotes, admin tables) scroll
 *      inside here, so the top bar and side nav stay visible.
 *
 * `min-h-0` on the flex row lets children shrink so
 * `overflow-y-auto` actually engages rather than being forced open by
 * a tall child. `overflow-x-hidden` on `<main>` prevents any stray
 * horizontal scroll on the whole page; tables that need horizontal
 * scroll already do so inside their own scroll containers.
 */
export function AppShell() {
  return (
    <div className="flex h-dvh flex-col overflow-hidden bg-slate-50">
      <TopNav />
      <div className="flex min-h-0 flex-1">
        <SideNav />
        <main
          className="min-w-0 flex-1 overflow-y-auto overflow-x-hidden px-4 py-6 lg:px-8"
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
