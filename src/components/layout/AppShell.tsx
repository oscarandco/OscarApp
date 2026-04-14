import { Outlet } from 'react-router-dom'

import { SideNav } from '@/components/layout/SideNav'
import { TopNav } from '@/components/layout/TopNav'

export function AppShell() {
  return (
    <div className="flex min-h-dvh flex-col bg-slate-50">
      <TopNav />
      <div className="flex flex-1">
        <SideNav />
        <main className="min-w-0 flex-1 px-4 py-6 lg:px-8">
          <div className="w-full max-w-[85rem]">
            <Outlet />
          </div>
        </main>
      </div>
    </div>
  )
}
