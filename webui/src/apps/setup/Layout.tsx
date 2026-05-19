import { Head } from "@inertiajs/react"
import type React from "react"
import logoDark from "@/assets/logo-dark.svg"
import backgroundImageUrl from "./marjan-taghipour-0fof1Z4CwQo-unsplash.jpg"

const BACKGROUND_IMAGE = `url(${backgroundImageUrl})`

interface SetupLayoutProps {
  title: string
  appName?: string
  subtitle?: string
  headerActions?: React.ReactNode
  children?: React.ReactNode
}

export default function SetupLayout({
  title,
  appName = "BullX",
  subtitle = "Setup",
  headerActions,
  children,
}: SetupLayoutProps) {
  return (
    <main
      data-theme="dark"
      className="relative isolate min-h-screen bg-background bg-cover bg-center bg-no-repeat text-foreground"
      style={{ backgroundImage: BACKGROUND_IMAGE }}>
      <Head title={title} />
      <div className="absolute inset-0 -z-10 bg-background/80" aria-hidden="true" />

      <div className="mx-auto flex min-h-screen w-full max-w-6xl flex-col px-4 py-5 sm:px-6 lg:px-8">
        <header className="flex h-12 shrink-0 items-center justify-between gap-3">
          <div className="flex min-w-0 items-center gap-3">
            <span className="flex size-8 shrink-0 items-center justify-center bg-card">
              <img src={logoDark} className="size-5" alt="BullX Logo" />
            </span>
            <div className="min-w-0">
              <p className="truncate text-sm font-semibold">{appName}</p>
              <p className="truncate text-xs text-muted-foreground">{subtitle}</p>
            </div>
          </div>
          {headerActions ? <div className="shrink-0">{headerActions}</div> : null}
        </header>

        {children}
      </div>
    </main>
  )
}
