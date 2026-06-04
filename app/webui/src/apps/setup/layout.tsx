import type { ReactNode } from 'react'
import logoDark from '@/assets/logo-dark.svg'
import backgroundImageUrl from './marjan-taghipour-0fof1Z4CwQo-unsplash.jpg'

export function SetupLayout({ children }: { children: ReactNode }) {
  return (
    <main
      data-theme="dark"
      className="relative isolate min-h-screen bg-background bg-cover bg-center bg-no-repeat text-foreground"
      style={{ backgroundImage: `url(${backgroundImageUrl})` }}>
      <div className="absolute inset-0 -z-10 bg-background/80" aria-hidden="true" />
      <div className="mx-auto flex min-h-screen w-full max-w-6xl flex-col px-4 py-5 sm:px-6 lg:px-8">
        <header className="flex h-12 shrink-0 items-center justify-between gap-3">
          <div className="flex min-w-0 items-center gap-3">
            <span className="flex size-8 shrink-0 items-center justify-center bg-card">
              <img src={logoDark} className="size-5" alt="BullX Logo" />
            </span>
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold">BullX</p>
              <p className="truncate text-xs text-muted-foreground">Setup</p>
            </div>
          </div>
        </header>
        {children}
      </div>
    </main>
  )
}
